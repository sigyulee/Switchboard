import BridgeCore
import Foundation
import RecorderKit
// The SDK's TranslationSession reference type lacks Sendable annotations. Each
// instance stays with this actor's one owned job; only one translate call is in
// flight, and pause requests cancellation before joining that job. No session is
// exposed to the UI or shared with another processor. Keep this SDK import scoped.
@preconcurrency import Translation

public struct StoredTranscriptProgress: Sendable {
    public let configuration: TranscriptConfiguration?
    public let completedThrough: [AudioSide: Int64]
    public let remainingIntervals: [AudioSide: [SessionInterval]]
    public let retryableTranslationCount: Int
    public var needsConfiguration: Bool { configuration == nil }
    public var hasWork: Bool {
        !needsConfiguration
            && (remainingIntervals.values.contains { !$0.isEmpty } || retryableTranslationCount > 0)
    }
}

public enum StoredTranscriptDisposition: String, Sendable {
    case completed, paused, incomplete, noWork, needsConfiguration
}

public struct StoredTranscriptResult: Sendable {
    public let disposition: StoredTranscriptDisposition
    public let progress: StoredTranscriptProgress
    public let states: [AudioSide: TranscriptSideState]
    public let sourceFailures: [AudioSide: String]
}

/// One explicitly requested saved-package job. The parent must await pause before
/// starting a live session or moving this package. No capture, PCM spool, or rendering.
@available(macOS 26.0, *)
public actor StoredTranscriptProcessor {
    private struct ProductionResult: Sendable {
        let side: AudioSide
        let acceptedThrough: Int64?
        let failure: String?
    }
    private var operation: Task<StoredTranscriptResult, any Error>?
    private var operationID: UUID?
    private var translations: [String: TranslationSession] = [:]

    public init() {}

    /// Event callbacks must not await pause inline; pause joins those callbacks.
    public func process(
        item: RecordingItem, session: SessionManifest? = nil,
        onEvent: @escaping @Sendable (TranscriptEvent) async -> Void = { _ in }
    ) async throws -> StoredTranscriptResult {
        guard operation == nil else { throw TranscriptFailure.alreadyRunning }
        let id = UUID()
        let task = Task { try await self.execute(item: item, session: session, onEvent: onEvent) }
        operationID = id
        operation = task
        defer {
            if operationID == id {
                operation = nil
                operationID = nil
                translations = [:]
            }
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Cancel unaccepted replay work, then join accepted-input drain and checkpoint persistence.
    public func pause() async {
        guard let operation else { return }
        operation.cancel()
        for session in translations.values { session.cancel() }
        _ = try? await operation.value
    }

    /// Metadata only. Calling this never starts models or audio processing.
    public static func progress(item: RecordingItem, session: SessionManifest? = nil) async throws
        -> StoredTranscriptProgress
    {
        let (item, session) = try load(item: item, session: session)
        let journal = try TranscriptJournal(sessionID: item.id, directory: item.directory)
        return try await progress(item: item, session: session, journal: journal)
    }

    private static func progress(
        item: RecordingItem, session: SessionManifest?, journal: TranscriptJournal
    ) async throws -> StoredTranscriptProgress {
        let entries = await journal.snapshot()
        let checkpoints = await journal.completedThrough()
        let gaps = await journal.gaps()
        return StoredTranscriptProgress(
            configuration: await journal.configuration(), completedThrough: checkpoints,
            remainingIntervals: try eligibleIntervals(
                manifest: item.manifest, session: session, completedThrough: checkpoints,
                finalEntries: entries, unrecoveredGaps: gaps),
            retryableTranslationCount: retryableTranslations(entries).count)
    }

    private func execute(
        item: RecordingItem, session: SessionManifest?,
        onEvent: @escaping @Sendable (TranscriptEvent) async -> Void
    ) async throws -> StoredTranscriptResult {
        let (item, session) = try Self.load(item: item, session: session)
        let journal = try TranscriptJournal(sessionID: item.id, directory: item.directory)
        let initial = try await Self.progress(item: item, session: session, journal: journal)
        guard let configuration = initial.configuration else {
            return StoredTranscriptResult(
                disposition: .needsConfiguration, progress: initial, states: [:], sourceFailures: [:])
        }
        guard initial.hasWork else {
            return StoredTranscriptResult(
                disposition: .noWork, progress: initial, states: [:], sourceFailures: [:])
        }
        let retries = Self.retryableTranslations(await journal.snapshot())
        let token = await journal.beginGeneration()
        let engine = LiveTranscriptEngine()
        var accepted: [AudioSide: Int64] = [:]
        var failures: [AudioSide: String] = [:]
        var states: [AudioSide: TranscriptSideState] = [:]
        do {
            guard
                try await journal.prepareCheckpoints(
                    durationFrames: item.manifest.durationFrames, token: token)
            else {
                throw TranscriptFailure.staleSession
            }
            if initial.remainingIntervals.values.contains(where: { !$0.isEmpty }), !Task.isCancelled {
                let feeds = try await engine.start(
                    configuration: configuration, journal: journal, token: token, onEvent: onEvent)
                let production = await withTaskGroup(
                    of: ProductionResult.self, returning: [ProductionResult].self
                ) { group in
                    for side in AudioSide.allCases {
                        let intervals = initial.remainingIntervals[side, default: []]
                        group.addTask {
                            await Self.produce(item: item, side: side, intervals: intervals, feeds: feeds)
                        }
                    }
                    var results: [ProductionResult] = []
                    for await result in group { results.append(result) }
                    return results
                }
                for result in production {
                    if let frame = result.acceptedThrough { accepted[result.side] = frame }
                    if let failure = result.failure { failures[result.side] = failure }
                }
                let completion = await engine.stop()
                states = completion.states
                guard
                    try await journal.commitCompletedThrough(
                        accepted, completion: completion, durationFrames: item.manifest.durationFrames,
                        token: token)
                else { throw TranscriptFailure.staleSession }
                for (side, message) in failures {
                    if var state = states[side], state.speech == .stopped || state.speech == .ready {
                        state.speech = .failed
                        state.message = message
                        states[side] = state
                        await onEvent(.state(state))
                    }
                }
            }
            if !Task.isCancelled {
                try await retryTranslations(
                    retries, configuration: configuration, journal: journal, token: token,
                    states: &states, onEvent: onEvent)
            }
            let final = try await Self.progress(item: item, session: session, journal: journal)
            await journal.invalidate(token: token)
            let disposition: StoredTranscriptDisposition =
                Task.isCancelled ? .paused : (final.hasWork || !failures.isEmpty ? .incomplete : .completed)
            return StoredTranscriptResult(
                disposition: disposition, progress: final, states: states, sourceFailures: failures)
        } catch {
            // Even a cancelled producer must drain packets already admitted by the feeds.
            let completion = await engine.stop()
            var checkpointFailure: (any Error)?
            if !accepted.isEmpty {
                do {
                    guard
                        try await journal.commitCompletedThrough(
                            accepted, completion: completion, durationFrames: item.manifest.durationFrames,
                            token: token)
                    else { throw TranscriptFailure.staleSession }
                } catch { checkpointFailure = error }
            }
            await journal.invalidate(token: token)
            if let checkpointFailure { throw checkpointFailure }
            if error is CancellationError {
                let final = try await Self.progress(item: item, session: session, journal: journal)
                return StoredTranscriptResult(
                    disposition: .paused, progress: final, states: completion.states, sourceFailures: failures
                )
            }
            throw error
        }
    }

    private static func produce(
        item: RecordingItem, side: AudioSide, intervals: [SessionInterval], feeds: TranscriptFeeds
    ) async -> ProductionResult {
        var accepted: Int64?
        do {
            let reader = try RecordingAudioReader(item: item, side: side)
            for interval in intervals {
                var frame = interval.startFrame
                while frame < interval.endFrame {
                    if Task.isCancelled {
                        return ProductionResult(side: side, acceptedThrough: accepted, failure: nil)
                    }
                    let count = Int(min(4_800, interval.endFrame - frame))
                    let samples = try reader.read(at: frame, frames: count)
                    guard await feeds.appendRecorded(side: side, samples: samples, startFrame: frame) else {
                        return ProductionResult(
                            side: side, acceptedThrough: accepted,
                            failure: Task.isCancelled
                                ? nil : "The speech source stopped accepting saved audio.")
                    }
                    frame += Int64(count)
                    accepted = frame
                }
            }
            return ProductionResult(side: side, acceptedThrough: accepted, failure: nil)
        } catch {
            return ProductionResult(
                side: side, acceptedThrough: accepted,
                failure: String(error.localizedDescription.prefix(2048)))
        }
    }

    private func retryTranslations(
        _ entries: [TranscriptEntry], configuration: TranscriptConfiguration, journal: TranscriptJournal,
        token: TranscriptSessionToken, states: inout [AudioSide: TranscriptSideState],
        onEvent: @escaping @Sendable (TranscriptEvent) async -> Void
    ) async throws {
        let availability = LanguageAvailability()
        for entry in entries {
            guard !Task.isCancelled else { return }
            var translated: String?
            var message: String?
            let status: TranscriptTranslationStatus
            if configuration.skipsTranslation(for: entry.side) {
                status = .notNeeded
            } else {
                let source = Locale.Language(
                    identifier: configuration.sourceLocaleIdentifier(for: entry.side))
                let target = Locale.Language(identifier: configuration.targetLocaleIdentifier)
                let available = await availability.status(from: source, to: target)
                guard !Task.isCancelled else { return }
                if available != .installed {
                    status = available == .supported ? .downloadRequired : .unsupported
                    message =
                        available == .supported
                        ? "Translation models are not installed for this language pair."
                        : "Translation is not supported for this language pair."
                } else {
                    let key =
                        TranscriptConfiguration.languageKey(
                            configuration.sourceLocaleIdentifier(for: entry.side))
                        + ">" + TranscriptConfiguration.languageKey(configuration.targetLocaleIdentifier)
                    let session: TranslationSession
                    if let existing = translations[key] {
                        session = existing
                    } else {
                        session = TranslationSession(installedSource: source, target: target)
                        translations[key] = session
                    }
                    do {
                        let response = try await session.translate(entry.original)
                        guard !Task.isCancelled else { return }
                        let text = response.targetText.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty, text.utf8.count <= TranscriptLimits.maximumTextBytes else {
                            throw TranscriptFailure.invalidEntry
                        }
                        translated = text
                        status = .translated
                    } catch {
                        guard !Task.isCancelled else { return }
                        status = .failed
                        message = String(error.localizedDescription.prefix(2048))
                    }
                }
            }
            guard
                try await journal.updateTranslation(
                    entryID: entry.id, original: entry.original, translation: translated, status: status,
                    token: token)
            else { throw TranscriptFailure.staleSession }
            var updated = entry
            updated.translation = translated
            updated.translationStatus = status
            await onEvent(.upsert(updated))
            var state =
                states[entry.side]
                ?? TranscriptSideState(side: entry.side, speech: .stopped, translation: .ready)
            switch status {
            case .translated: state.translation = .ready
            case .notNeeded: state.translation = .notNeeded
            case .downloadRequired: state.translation = .downloadRequired
            case .unsupported: state.translation = .unsupported
            default: state.translation = .failed
            }
            if let message {
                state.message = message
            } else if state.speech == .ready || state.speech == .stopped {
                state.message = nil
            }
            states[entry.side] = state
            await onEvent(.state(state))
        }
    }

    public static func retryableTranslations(_ entries: [TranscriptEntry]) -> [TranscriptEntry] {
        entries.filter {
            $0.isFinal
                && [.pending, .interrupted, .failed, .dropped, .downloadRequired, .unsupported].contains(
                    $0.translationStatus)
        }
    }

    /// Production planning policy: recorded PCM intersected with the approved
    /// initial backfill and enabled intervals, minus durable progress/final text.
    public static func eligibleIntervals(
        manifest: RecordingManifest, session: SessionManifest?, completedThrough: [AudioSide: Int64],
        finalEntries: [TranscriptEntry], unrecoveredGaps: [TranscriptGap] = []
    ) throws -> [AudioSide: [SessionInterval]] {
        try manifest.validate()
        guard manifest.durationFrames <= TranscriptLimits.maximumFrame,
            completedThrough.values.allSatisfy({ $0 >= 0 && $0 <= manifest.durationFrames })
        else { throw TranscriptFailure.invalidAudio }
        for entry in finalEntries { try entry.validate() }
        guard unrecoveredGaps.count <= TranscriptLimits.maximumGaps else {
            throw TranscriptFailure.capacityExceeded
        }
        for gap in unrecoveredGaps { try gap.validate() }
        let eligible: [SessionInterval]
        if let session {
            try session.validate()
            guard session.id == manifest.id, session.createdAt == manifest.createdAt else {
                throw TranscriptFailure.invalidEntry
            }
            var intervals = session.state.transcriptionIntervals
            if let first = intervals.first, first.startFrame > 0 {
                intervals.insert(try SessionInterval(startFrame: 0, frames: first.startFrame), at: 0)
            }
            eligible = try union(intervals)
        } else {
            eligible =
                manifest.durationFrames > 0
                ? [try SessionInterval(startFrame: 0, frames: manifest.durationFrames)] : []
        }
        var result: [AudioSide: [SessionInterval]] = [:]
        for side in AudioSide.allCases {
            let recorded = try union(
                manifest.segments.filter { $0.side == side }.map {
                    try SessionInterval(startFrame: $0.startFrame, frames: $0.frames)
                })
            let matched = try intersection(recorded, eligible)
            let floor = completedThrough[side, default: 0]
            let afterCheckpoint = try matched.compactMap { interval -> SessionInterval? in
                let start = max(floor, interval.startFrame)
                return start < interval.endFrame
                    ? try SessionInterval(startFrame: start, frames: interval.endFrame - start) : nil
            }
            let known = try union(
                finalEntries.filter { $0.isFinal && $0.side == side && $0.endFrame > $0.startFrame }.map {
                    try SessionInterval(startFrame: $0.startFrame, frames: $0.endFrame - $0.startFrame)
                })
            // A final utterance can span an input hole. Its text is durable, but that
            // timestamp envelope is not proof that the missing recorded audio was analyzed.
            let holes = try union(
                unrecoveredGaps.compactMap { gap -> SessionInterval? in
                    guard gap.side == side else { return nil }
                    let start = max(floor, gap.startFrame)
                    guard gap.endFrame > start else { return nil }
                    return try SessionInterval(startFrame: start, frames: gap.endFrame - start)
                })
            let completedTextCoverage = try subtract(holes, from: known)
            result[side] = try subtract(completedTextCoverage, from: afterCheckpoint)
        }
        return result
    }

    private static func union(_ intervals: [SessionInterval]) throws -> [SessionInterval] {
        var result: [SessionInterval] = []
        for interval in intervals.sorted(by: { $0.startFrame < $1.startFrame }) {
            if let previous = result.last, interval.startFrame <= previous.endFrame {
                result[result.count - 1] = try SessionInterval(
                    startFrame: previous.startFrame,
                    frames: max(previous.endFrame, interval.endFrame) - previous.startFrame)
            } else {
                result.append(interval)
            }
        }
        return result
    }

    private static func intersection(_ a: [SessionInterval], _ b: [SessionInterval]) throws
        -> [SessionInterval]
    {
        var result: [SessionInterval] = []
        var i = 0
        var j = 0
        while i < a.count && j < b.count {
            let start = max(a[i].startFrame, b[j].startFrame)
            let end = min(a[i].endFrame, b[j].endFrame)
            if end > start { result.append(try SessionInterval(startFrame: start, frames: end - start)) }
            if a[i].endFrame <= b[j].endFrame { i += 1 } else { j += 1 }
        }
        return result
    }

    private static func subtract(_ excluded: [SessionInterval], from intervals: [SessionInterval]) throws
        -> [SessionInterval]
    {
        var result: [SessionInterval] = []
        var index = 0
        for interval in intervals {
            var cursor = interval.startFrame
            while index < excluded.count && excluded[index].endFrame <= cursor { index += 1 }
            var next = index
            while next < excluded.count && excluded[next].startFrame < interval.endFrame {
                if excluded[next].startFrame > cursor {
                    result.append(
                        try SessionInterval(startFrame: cursor, frames: excluded[next].startFrame - cursor))
                }
                cursor = max(cursor, min(interval.endFrame, excluded[next].endFrame))
                if cursor == interval.endFrame { break }
                next += 1
            }
            index = next
            if cursor < interval.endFrame {
                result.append(try SessionInterval(startFrame: cursor, frames: interval.endFrame - cursor))
            }
        }
        return result
    }

    private static func load(item: RecordingItem, session: SessionManifest?) throws -> (
        RecordingItem, SessionManifest?
    ) {
        let directory = item.directory
        guard directory.isFileURL, directory.path.utf8.count <= 4096, !directory.path.contains("\0") else {
            throw TranscriptFailure.invalidPath
        }
        let info = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard info.isDirectory == true, info.isSymbolicLink != true else {
            throw TranscriptFailure.invalidPath
        }
        let file = directory.appendingPathComponent("manifest.json")
        let metadata = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard metadata.isRegularFile == true, metadata.isSymbolicLink != true,
            let size = metadata.fileSize, size <= TranscriptLimits.maximumFileBytes
        else { throw TranscriptFailure.invalidPath }
        let manifest = try RecordingManifest.load(from: directory)
        guard manifest.id == item.id, manifest.createdAt == item.manifest.createdAt else {
            throw TranscriptFailure.invalidEntry
        }
        let sessionFile = directory.appendingPathComponent(SessionManifest.filename)
        let attributes: [FileAttributeKey: Any]?
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: sessionFile.path)
        } catch let error as CocoaError
            where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile
        {
            attributes = nil
        }
        var storedSession = session
        if let attributes {
            // A renamed package must not lose its explicit transcription-OFF policy.
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                let size = attributes[.size] as? NSNumber, size.int64Value > 0,
                size.int64Value <= 4 * 1_024 * 1_024
            else { throw TranscriptFailure.invalidPath }
            let data = try Data(contentsOf: sessionFile)
            guard data.count <= 4 * 1_024 * 1_024 else { throw TranscriptFailure.invalidPath }
            storedSession = try JSONDecoder().decode(SessionManifest.self, from: data)
        } else if directory.pathExtension.lowercased() == SessionManifest.packageExtension {
            throw TranscriptFailure.invalidEntry
        }
        return (RecordingItem(directory: directory, manifest: manifest), storedSession)
    }
}
