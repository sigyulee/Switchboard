import AVFAudio
import BridgeCore
import CoreMedia
import Foundation
import Speech

public struct TranscriptCompletion: Equatable, Sendable {
    public let drainedSources: Set<AudioSide>
    public let states: [AudioSide: TranscriptSideState]
    public let wasCancelled: Bool
    public let delivery: TranscriptDeliveryReceipt?

    /// Finalization alone cannot erase a result-stream or resource failure.
    public init(
        finalizedSources: Set<AudioSide>, states: [AudioSide: TranscriptSideState],
        wasCancelled: Bool = false, delivery: TranscriptDeliveryReceipt? = nil
    ) {
        var states = states
        var drained: Set<AudioSide> = []
        if !wasCancelled {
            for side in finalizedSources where states[side]?.speech == .ready {
                states[side]?.speech = .stopped
                drained.insert(side)
            }
        }
        drainedSources = drained
        self.states = states
        self.wasCancelled = wasCancelled
        self.delivery = delivery
    }
}

/// Owns Speech/Translation work only. The caller retains the returned feeds and owns relay/recording.
@available(macOS 26.0, *)
public actor LiveTranscriptEngine {
    private struct SideRuntime {
        let analyzer: SpeechAnalyzer
        let results: Task<Void, Never>
        let lease: SpeechLocaleLease
    }
    private struct Run {
        let id: UUID
        let configuration: TranscriptConfiguration
        let journal: TranscriptJournal
        let token: TranscriptSessionToken
        let feeds: TranscriptFeeds
        let onEvent: @Sendable (TranscriptEvent) async -> Void
        var sides: [AudioSide: SideRuntime] = [:]
        var translations: [String: TranscriptTranslationWorker] = [:]
        var states: [AudioSide: TranscriptSideState] = [:]
        var partialIDs: [AudioSide: UUID] = [:]
        var finalIDs: [AudioSide: [Int64: UUID]] = [:]
        var stopping = false
    }
    private var run: Run?
    private var startOperation: Task<TranscriptFeeds, any Error>?
    private var stopOperation: Task<TranscriptCompletion, Never>?
    private var lastCompletion = TranscriptCompletion(finalizedSources: [], states: [:])

    public init() {}

    public func start(
        configuration: TranscriptConfiguration, journal: TranscriptJournal,
        token: TranscriptSessionToken,
        onEvent: @escaping @Sendable (TranscriptEvent) async -> Void
    ) async throws -> TranscriptFeeds {
        guard run == nil, startOperation == nil, stopOperation == nil else {
            throw TranscriptFailure.alreadyRunning
        }
        lastCompletion = TranscriptCompletion(finalizedSources: [], states: [:])
        let operation = Task {
            try await self.startRun(
                configuration: configuration, journal: journal, token: token, onEvent: onEvent)
        }
        startOperation = operation
        do {
            let feeds = try await withTaskCancellationHandler {
                try await operation.value
            } onCancel: {
                operation.cancel()
            }
            startOperation = nil
            return feeds
        } catch {
            startOperation = nil
            throw error
        }
    }

    private func startRun(
        configuration: TranscriptConfiguration, journal: TranscriptJournal,
        token: TranscriptSessionToken,
        onEvent: @escaping @Sendable (TranscriptEvent) async -> Void
    ) async throws -> TranscriptFeeds {
        guard run == nil else { throw TranscriptFailure.alreadyRunning }
        try configuration.validate()
        guard await journal.isCurrent(token) else { throw TranscriptFailure.staleSession }
        guard
            try await journal.prepareCheckpoints(durationFrames: TranscriptLimits.maximumFrame, token: token)
        else {
            throw TranscriptFailure.staleSession
        }
        guard run == nil else { throw TranscriptFailure.alreadyRunning }
        let id = UUID()
        let feeds = TranscriptFeeds()
        run = Run(
            id: id, configuration: configuration, journal: journal, token: token, feeds: feeds,
            onEvent: onEvent)
        let capabilities = await TranscriptCapabilities.check(configuration: configuration)
        guard run?.id == id, !Task.isCancelled else {
            feeds.finish()
            if run?.id == id { await cancelCurrent() }
            throw CancellationError()
        }
        run?.states = capabilities.states
        for side in AudioSide.allCases {
            guard run?.id == id, run?.stopping == false, !Task.isCancelled else { break }
            guard let state = capabilities.states[side] else { continue }
            await emit(.state(state), id: id)
            guard state.speech == .ready, let identifier = capabilities.speechLocaleIdentifiers[side] else {
                feeds.finish(side: side)
                continue
            }
            var pendingLease: SpeechLocaleLease?
            var pendingAnalyzer: SpeechAnalyzer?
            var acquiringReservation = true
            do {
                let lease = try await SpeechLocaleReservations.shared.acquire(
                    locale: Locale(identifier: identifier))
                acquiringReservation = false
                pendingLease = lease
                guard run?.id == id, run?.stopping == false, !Task.isCancelled else {
                    throw CancellationError()
                }
                let transcriber = SpeechTranscriber(
                    locale: Locale(identifier: identifier),
                    preset: .timeIndexedProgressiveTranscription)
                let analyzer = SpeechAnalyzer(
                    modules: [transcriber], options: .init(priority: .utility, modelRetention: .whileInUse))
                pendingAnalyzer = analyzer
                guard
                    let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
                else {
                    throw TranscriptFailure.unavailableFormat
                }
                let converter = try TranscriptPCMConverter(outputFormat: format)
                try await analyzer.prepareToAnalyze(in: format)
                guard run?.id == id, run?.stopping == false, !Task.isCancelled else {
                    throw CancellationError()
                }
                let sequence = TranscriptAudioSequence(feeds: feeds, side: side, converter: converter) {
                    [weak self] gap in
                    await self?.emit(.gap(gap), id: id)
                }
                let resultSequence = transcriber.results
                let results = Task { [weak self] in
                    do {
                        for try await result in resultSequence {
                            guard !Task.isCancelled else { break }
                            await self?.receive(result, side: side, id: id)
                        }
                    } catch {
                        guard !Task.isCancelled else { return }
                        await self?.sideFailed(side, id: id, message: error.localizedDescription)
                    }
                }
                run?.sides[side] = SideRuntime(analyzer: analyzer, results: results, lease: lease)
                pendingLease = nil
                pendingAnalyzer = nil
                try await analyzer.start(inputSequence: sequence)
                if state.translation == .ready {
                    await prepareTranslation(side: side, id: id)
                }
            } catch {
                if let pendingAnalyzer { await pendingAnalyzer.cancelAndFinishNow() }
                if let pendingLease { await SpeechLocaleReservations.shared.release(pendingLease) }
                if run?.id == id {
                    await sideFailed(
                        side, id: id, message: error.localizedDescription,
                        state: acquiringReservation ? .resourceLimit : .failed)
                }
            }
        }
        guard run?.id == id, !Task.isCancelled else {
            feeds.finish()
            if run?.id == id { await cancelCurrent() }
            throw CancellationError()
        }
        return feeds
    }

    /// Finish all accepted input and final speech results, then drain bounded translation work.
    /// Event callbacks must not await stop inline: stop joins those callbacks.
    @discardableResult public func stop() async -> TranscriptCompletion {
        if let stopOperation {
            return await stopOperation.value
        }
        let startup = startOperation
        startup?.cancel()
        let operation = Task {
            _ = try? await startup?.value
            return await self.drainCurrent()
        }
        stopOperation = operation
        let completion = await operation.value
        lastCompletion = completion
        stopOperation = nil
        return completion
    }

    private func drainCurrent() async -> TranscriptCompletion {
        guard let current = run, !current.stopping else { return lastCompletion }
        let id = current.id
        var finalizedSources: Set<AudioSide> = []
        run?.stopping = true
        current.feeds.finish()
        for (side, runtime) in current.sides {
            do {
                try await runtime.analyzer.finalizeAndFinishThroughEndOfInput()
                finalizedSources.insert(side)
            } catch {
                await runtime.analyzer.cancelAndFinishNow()
                await sideFailed(side, id: id, message: error.localizedDescription)
            }
            await runtime.results.value
        }
        guard run?.id == id else { return lastCompletion }
        let translations = Array(run?.translations.values ?? [:].values)
        for translation in translations { await translation.finish() }
        guard run?.id == id else { return lastCompletion }
        for runtime in current.sides.values { await SpeechLocaleReservations.shared.release(runtime.lease) }
        guard run?.id == id else { return lastCompletion }
        for side in AudioSide.allCases {
            for gap in current.feeds.takeGaps(side: side) { await emit(.gap(gap), id: id) }
        }
        guard run?.id == id else { return lastCompletion }
        let completion = TranscriptCompletion(
            finalizedSources: finalizedSources, states: run?.states ?? [:],
            delivery: current.feeds.deliveryReceipt())
        run?.states = completion.states
        for side in AudioSide.allCases {
            if let state = completion.states[side] { await emit(.state(state), id: id) }
        }
        guard run?.id == id else { return lastCompletion }
        if run?.id == id { run = nil }
        return completion
    }

    /// Cancellation invalidates this generation before any awaited cleanup.
    public func cancel() async {
        let startup = startOperation
        startup?.cancel()
        await cancelCurrent()
        _ = try? await startup?.value
        _ = await stopOperation?.value
    }

    private func cancelCurrent() async {
        guard let current = run else { return }
        lastCompletion = TranscriptCompletion(
            finalizedSources: [], states: current.states, wasCancelled: true)
        run = nil
        current.feeds.finish()
        await current.journal.invalidate(token: current.token)
        for runtime in current.sides.values { runtime.results.cancel() }
        for runtime in current.sides.values { await runtime.analyzer.cancelAndFinishNow() }
        for translation in current.translations.values { await translation.cancel() }
        for runtime in current.sides.values {
            await runtime.results.value
            await SpeechLocaleReservations.shared.release(runtime.lease)
        }
    }

    private func prepareTranslation(side: AudioSide, id: UUID) async {
        guard let current = run, current.id == id else { return }
        let key = pairKey(configuration: current.configuration, side: side)
        guard current.translations[key] == nil else { return }
        let worker = TranscriptTranslationWorker(
            source: current.configuration.sourceLocaleIdentifier(for: side),
            target: current.configuration.targetLocaleIdentifier
        ) { [weak self] entry, text, status in
            await self?.translated(entry, text: text, status: status, id: id)
        }
        run?.translations[key] = worker
        await worker.start()
    }

    private func receive(_ result: SpeechTranscriber.Result, side: AudioSide, id: UUID) async {
        guard let current = run, current.id == id else { return }
        do {
            let start = try frame(result.range.start)
            let end = try frame(CMTimeRangeGetEnd(result.range))
            let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            let entryID = current.finalIDs[side]?[start] ?? current.partialIDs[side] ?? UUID()
            var entry = TranscriptEntry(
                id: entryID, side: side, startFrame: start, endFrame: end,
                original: text, isFinal: result.isFinal)
            if result.isFinal {
                switch current.states[side]?.translation {
                case .ready: entry.translationStatus = .pending
                case .notNeeded: entry.translationStatus = .notNeeded
                case .downloadRequired: entry.translationStatus = .downloadRequired
                default: entry.translationStatus = .unsupported
                }
            }
            let accepted = try await current.journal.upsert(entry, token: current.token)
            guard run?.id == id, accepted else { return }
            if result.isFinal {
                run?.partialIDs[side] = nil
                if (run?.finalIDs[side]?.count ?? 0) < TranscriptLimits.maximumEntries {
                    run?.finalIDs[side, default: [:]][start] = entry.id
                }
                await emit(.final(entry), id: id)
                if entry.translationStatus == .pending {
                    await prepareTranslation(side: side, id: id)
                    let key = pairKey(configuration: current.configuration, side: side)
                    if let translation = run?.translations[key], await translation.enqueue(entry) { return }
                    await translated(entry, text: nil, status: .dropped, id: id)
                }
            } else {
                run?.partialIDs[side] = entry.id
                await emit(.partial(entry), id: id)
            }
        } catch { await sideFailed(side, id: id, message: error.localizedDescription) }
    }

    private func translated(
        _ entry: TranscriptEntry, text: String?, status: TranscriptTranslationStatus, id: UUID
    ) async {
        guard let current = run, current.id == id else { return }
        do {
            let accepted = try await current.journal.updateTranslation(
                entryID: entry.id, original: entry.original,
                translation: text, status: status, token: current.token)
            guard run?.id == id, accepted else { return }
            var updated = entry
            updated.translation = text
            updated.translationStatus = status
            await emit(.upsert(updated), id: id)
        } catch {
            guard var state = run?.states[entry.side], run?.id == id else { return }
            state.message = error.localizedDescription
            state.translation = .failed
            run?.states[entry.side] = state
            await emit(.state(state), id: id)
        }
    }

    private func sideFailed(
        _ side: AudioSide, id: UUID, message: String,
        state failureState: TranscriptModelState = .failed
    ) async {
        guard let current = run, current.id == id else { return }
        current.feeds.finish(side: side)
        var state =
            current.states[side]
            ?? TranscriptSideState(side: side, speech: .failed, translation: .unsupported)
        state.speech = failureState
        state.message = String(message.prefix(2048))
        run?.states[side] = state
        await emit(.state(state), id: id)
    }

    private func emit(_ event: TranscriptEvent, id: UUID) async {
        guard let current = run, current.id == id, await current.journal.isCurrent(current.token),
            run?.id == id
        else { return }
        if case .gap(let gap) = event {
            do {
                guard try await current.journal.recordGap(gap, token: current.token), run?.id == id else {
                    return
                }
            } catch {
                guard run?.id == id else { return }
                var state =
                    run?.states[gap.side]
                    ?? TranscriptSideState(side: gap.side, speech: .failed, translation: .unsupported)
                state.message = "Could not save a transcription gap: \(error.localizedDescription)"
                state.speech = .failed
                run?.states[gap.side] = state
                await current.onEvent(.state(state))
                guard run?.id == id else { return }
            }
        }
        await current.onEvent(event)
    }

    private func pairKey(configuration: TranscriptConfiguration, side: AudioSide) -> String {
        TranscriptConfiguration.languageKey(configuration.sourceLocaleIdentifier(for: side)) + ">"
            + TranscriptConfiguration.languageKey(configuration.targetLocaleIdentifier)
    }

    private func frame(_ time: CMTime) throws -> Int64 {
        guard time.isNumeric, time.timescale > 0 else { throw TranscriptFailure.invalidEntry }
        let converted = CMTimeConvertScale(time, timescale: 48_000, method: .roundHalfAwayFromZero)
        guard converted.isNumeric, converted.value >= 0, converted.value <= TranscriptLimits.maximumFrame
        else {
            throw TranscriptFailure.invalidEntry
        }
        return converted.value
    }
}
