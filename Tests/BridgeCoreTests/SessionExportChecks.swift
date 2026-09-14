import BridgeCore
import Foundation
import RecorderKit
import Synchronization
import TranscriptKit

struct SessionExportChecks {
    func packageCopyPreservesAudioTextDescriptionAndOriginal() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let item = try fixture(in: root)
        let journal = try TranscriptJournal(sessionID: item.id, directory: item.directory)
        let token = await journal.beginGeneration()
        let entry = TranscriptEntry(
            side: .caller, startFrame: 120, endFrame: 480, original: "안녕하세요", isFinal: true,
            translation: "Hello", translationStatus: .translated)
        _ = try await journal.upsert(entry, token: token)
        let before = try contents(of: item.directory)
        let source = try SessionStore.prepareExport(of: item)
        let destination = root.appendingPathComponent("Exported.switchboard")

        let result = try SessionStore.exportCopy(of: source, to: destination)

        try expect(result.resolvingSymlinksInPath().path == destination.resolvingSymlinksInPath().path)
        try expect(contents(of: destination) == before)
        try expect(contents(of: item.directory) == before)
        try expect(RecordingLibrary.item(at: destination).id == item.id)
        let session = try SessionStore.metadata(in: destination)
        try expect(session.description == "A saved description\n설명")
        try expect(session.state.recordingIntervals == [SessionInterval(startFrame: 0, frames: 480)])
        try expect(session.state.transcriptionIntervals == [SessionInterval(startFrame: 120, frames: 840)])
        let copiedJournal = try TranscriptJournal(sessionID: item.id, directory: destination)
        let entries = await copiedJournal.snapshot()
        try expect(entries.count == 1 && entries[0].original == "안녕하세요")
        try expect(entries[0].translation == "Hello")
        try expect(noStaging(in: root))
    }

    func legacyExportUsesCanonicalFormatAndPreservesKnownMetadataAndMedia() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let item = try fixture(in: root, legacy: true)
        try expect(RecordingLibrary.item(at: item.directory).manifest == item.manifest)
        let journal = try TranscriptJournal(sessionID: item.id, directory: item.directory)
        let token = await journal.beginGeneration()
        let entry = TranscriptEntry(
            side: .caller, startFrame: 120, endFrame: 480, original: "보관한 대화", isFinal: true,
            translation: "Archived conversation", translationStatus: .translated)
        _ = try await journal.upsert(entry, token: token)
        let originalEntries = await journal.snapshot()
        let before = try contents(of: item.directory)
        let source = try SessionStore.prepareExport(of: item)
        try expect(source.fileExtension == SessionManifest.packageExtension)
        try expect(source.title == item.manifest.title)
        let destination = root.appendingPathComponent("Exported.switchboard")
        _ = try SessionStore.exportCopy(of: source, to: destination)

        var copied = try contents(of: destination)
        try expect(copied.removeValue(forKey: SessionManifest.filename) != nil)
        try expect(copied == before && contents(of: item.directory) == before)
        let reopened = try RecordingLibrary.item(at: destination)
        try expect(reopened.manifest == item.manifest && reopened.manifest.owner == .automatic)
        let session = try SessionStore.metadata(in: destination)
        try expect(session.id == item.id && session.title == item.manifest.title)
        try expect(session.createdAt == item.manifest.createdAt)
        try expect(session.durationFrames == item.manifest.durationFrames)
        try expect(!session.isDraft && session.state.lifecycle == .ended && session.description.isEmpty)
        try expect(!session.state.audioRecording && !session.state.transcription)
        try expect(session.state.recordingIntervals.isEmpty && session.state.transcriptionIntervals.isEmpty)
        let audio = try RecordingAudioReader(item: reopened, side: .caller)
        try expect(audio.read(at: 0, frames: 480) == [Float](repeating: 0.25, count: 960))
        let copiedJournal = try TranscriptJournal(sessionID: item.id, directory: destination)
        let copiedEntries = await copiedJournal.snapshot()
        try expect(copiedEntries == originalEntries)

        let secondDestination = root.appendingPathComponent("Exported again.switchboard")
        _ = try SessionStore.exportCopy(
            of: SessionStore.prepareExport(of: reopened), to: secondDestination)
        try expect(contents(of: secondDestination) == contents(of: destination))
        let legacyDestination = root.appendingPathComponent("New legacy.mihrecording")
        try expectThrows {
            _ = try SessionStore.validateExportDestination(legacyDestination, for: source)
        }
        try expectThrows {
            _ = try SessionStore.exportCopy(of: source, to: legacyDestination)
        }
        try expect(!FileManager.default.fileExists(atPath: legacyDestination.path) && noStaging(in: root))
    }

    func legacyExportPreservesExistingSessionHistory() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try fixture(in: root)
        let legacyPath = root.appendingPathComponent("Renamed.mihrecording")
        try FileManager.default.moveItem(at: original.directory, to: legacyPath)
        let item = try RecordingLibrary.item(at: legacyPath)
        let before = try contents(of: legacyPath)
        let source = try SessionStore.prepareExport(of: item)
        let destination = root.appendingPathComponent("Restored.switchboard")
        _ = try SessionStore.exportCopy(of: source, to: destination)
        try expect(contents(of: destination) == before && contents(of: legacyPath) == before)
        try expect(SessionStore.metadata(in: destination) == SessionStore.metadata(in: legacyPath))
        try expect(RecordingLibrary.item(at: destination).manifest == item.manifest)
    }

    func invalidLegacyMetadataIsRejectedBeforeExport() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let item = try fixture(in: root, legacy: true)
        let mutations: [(inout RecordingManifest) -> Void] = [
            { $0.version = 2 }, { $0.sampleRate = 44_100 }, { $0.durationFrames = -1 },
            { $0.status = .recording }, { $0.status = .finalizing },
            { $0.title = " \n" }, { $0.title = String(repeating: "a", count: 513) },
            { $0.title = "Invalid\0title" },
            {
                $0.segments = [
                    RecordingSegment(side: .caller, filename: "../outside.caf", startFrame: 0, frames: 1)
                ]
            },
            { $0.gaps = [AudioGap(side: .caller, startFrame: .max, frames: 1, reason: "Invalid")] },
        ]
        for mutate in mutations {
            var invalid = item.manifest
            mutate(&invalid)
            try JSONEncoder().encode(invalid).write(
                to: item.directory.appendingPathComponent("manifest.json"), options: .atomic)
            let before = try contents(of: item.directory)
            try expectThrows { _ = try SessionStore.prepareExport(of: item) }
            try expect(contents(of: item.directory) == before && noStaging(in: root))
            try expect(before[SessionManifest.filename] == nil)
        }
    }

    func legacyExportKeepsClosedStatusesAndTimelineBounds() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        for (index, status) in [RecordingStatus.complete, .recoverable, .failed].enumerated() {
            let directory = root.appendingPathComponent("Original-\(index).mihrecording")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var recording = RecordingManifest(title: "Archived recording", owner: .automatic)
            recording.status = status
            recording.durationFrames = index == 0 ? 0 : .max
            try recording.save(to: directory)
            let before = try contents(of: directory)
            let source = try SessionStore.prepareExport(of: RecordingLibrary.item(at: directory))
            let destination = root.appendingPathComponent("Exported-\(index).switchboard")
            _ = try SessionStore.exportCopy(of: source, to: destination)
            let session = try SessionStore.metadata(in: destination)
            try expect(session.durationFrames == recording.durationFrames)
            try expect(session.state.lifecycle == .ended && !session.state.effectiveAudioRecording)
            try expectThrows {
                var state = session.state
                try state.start()
            }
            try expect(RecordingLibrary.item(at: destination).manifest == recording)
            try expect(contents(of: directory) == before)
        }
    }

    func collisionsAndDestinationsInsideSourceAreRefused() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let item = try fixture(in: root)
        let child = item.directory.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)
        let source = try SessionStore.prepareExport(of: item)
        let alias = root.appendingPathComponent("source-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: item.directory)
        let collision = root.appendingPathComponent("Existing.switchboard")
        let sentinel = Data("An existing destination must survive".utf8)
        try sentinel.write(to: collision)
        let link = root.appendingPathComponent("Link.switchboard")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: item.directory)
        let destinations = [
            collision, item.directory, link, child.appendingPathComponent("Nested.switchboard"),
            alias.appendingPathComponent("Contents/Nested.switchboard"),
        ]
        let before = try contents(of: item.directory)
        for destination in destinations {
            try expectThrows { _ = try SessionStore.validateExportDestination(destination, for: source) }
            try expectThrows { _ = try SessionStore.exportCopy(of: source, to: destination) }
        }
        try expect(Data(contentsOf: collision) == sentinel)
        try expect(contents(of: item.directory) == before && noStaging(in: root))
        try expect(FileManager.default.contentsOfDirectory(atPath: child.path).isEmpty)
    }

    func sourceIdentityAndContentChangesRejectPreparedExport() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let item = try fixture(in: root)
        let source = try SessionStore.prepareExport(of: item)
        let destination = root.appendingPathComponent("Exported.switchboard")
        let moved = root.appendingPathComponent("Retained original.switchboard")
        try FileManager.default.moveItem(at: item.directory, to: moved)
        try FileManager.default.copyItem(at: moved, to: item.directory)
        try expectThrows { _ = try SessionStore.exportCopy(of: source, to: destination) }
        try expect(!FileManager.default.fileExists(atPath: destination.path))
        let current = try SessionStore.prepareExport(of: RecordingLibrary.item(at: item.directory))
        let changedBytes = Data("Changed after choosing Export".utf8)
        try changedBytes.write(
            to: item.directory.appendingPathComponent("Conversation.m4a"), options: .atomic)
        try expectThrows { _ = try SessionStore.exportCopy(of: current, to: destination) }
        try expect(!FileManager.default.fileExists(atPath: destination.path))
        try expect(
            Data(contentsOf: item.directory.appendingPathComponent("Conversation.m4a")) == changedBytes)
        var wrong = item.manifest
        wrong.id = UUID()
        try expectThrows {
            _ = try SessionStore.prepareExport(of: RecordingItem(directory: item.directory, manifest: wrong))
        }
        try expect(noStaging(in: root))
    }

    func symlinkPayloadAndUnfinishedPackagesAreRejected() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let item = try fixture(in: root)
        let linkedFile = item.directory.appendingPathComponent("linked.txt")
        let outside = root.appendingPathComponent("private.txt")
        let sentinel = Data("Must not be exported through a link".utf8)
        try sentinel.write(to: outside)
        try FileManager.default.createSymbolicLink(at: linkedFile, withDestinationURL: outside)
        try expectThrows { _ = try SessionStore.prepareExport(of: item) }
        try FileManager.default.removeItem(at: linkedFile)
        var active = item.manifest
        active.status = .recording
        try active.save(to: item.directory)
        try expectThrows { _ = try SessionStore.prepareExport(of: item) }
        try item.manifest.save(to: item.directory)
        var session = try SessionStore.metadata(in: item.directory)
        session.isDraft = true
        try JSONEncoder().encode(session).write(to: item.directory.appendingPathComponent("session.json"))
        try expectThrows { _ = try SessionStore.prepareExport(of: item) }
        try expect(Data(contentsOf: outside) == sentinel && noStaging(in: root))
    }

    func commitRacesPreserveTheSourceAndCompetingDestination() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        for (legacy, changesSource) in [(false, false), (false, true), (true, false), (true, true)] {
            let folder = root.appendingPathComponent("legacy-\(legacy)-source-\(changesSource)")
            let item = try fixture(in: folder, legacy: legacy)
            let source = try SessionStore.prepareExport(of: item)
            let destination = folder.appendingPathComponent("Exported.switchboard")
            let sentinel = Data("A competing writer must survive".utf8)
            let mutationTarget =
                changesSource ? item.directory.appendingPathComponent("Conversation.m4a") : destination
            let presenter = ExportRacePresenter(url: destination) {
                try sentinel.write(to: mutationTarget, options: .atomic)
            }
            NSFileCoordinator.addFilePresenter(presenter)
            defer { NSFileCoordinator.removeFilePresenter(presenter) }
            try expectThrows { _ = try SessionStore.exportCopy(of: source, to: destination) }
            try expect(presenter.invoked && presenter.failure == nil)
            try expect(Data(contentsOf: mutationTarget) == sentinel)
            try expect(RecordingLibrary.item(at: item.directory).id == item.id && noStaging(in: folder))
            if changesSource { try expect(!FileManager.default.fileExists(atPath: destination.path)) }
        }
    }

    func cancelledExportLeavesNoDestinationOrStaging() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let item = try fixture(in: root)
        let source = try SessionStore.prepareExport(of: item)
        let before = try contents(of: item.directory)
        let destination = root.appendingPathComponent("Cancelled.switchboard")
        let cancelled = await Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try SessionStore.exportCopy(of: source, to: destination)
                return false
            } catch is CancellationError {
                return true
            } catch { return false }
        }.value
        try expect(cancelled && !FileManager.default.fileExists(atPath: destination.path))
        try expect(contents(of: item.directory) == before && noStaging(in: root))
    }

    private func fixture(in root: URL, legacy: Bool = false) throws -> RecordingItem {
        let directory = root.appendingPathComponent(legacy ? "Original.mihrecording" : "Original.switchboard")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let createdAt = Date(timeIntervalSinceReferenceDate: 123_456)
        var recording = RecordingManifest(
            title: legacy ? "  Archived conversation\n" : "Saved conversation", createdAt: createdAt,
            owner: legacy ? .automatic : .manual)
        let recorder = ConversationRecorder()
        _ = try recorder.start(directory: directory, manifest: recording)
        try expect(recorder.append(side: .caller, samples: [Float](repeating: 0.25, count: 960), frame: 0))
        _ = try recorder.finish(durationFrames: 960)
        recording = try RecordingManifest.load(from: directory)
        recording.status = .complete
        try recording.save(to: directory)
        try Data("Preserve the existing rendered mix verbatim".utf8).write(
            to: directory.appendingPathComponent("Conversation.m4a"))
        if !legacy {
            var state = try SessionState(
                id: recording.id, name: recording.title, description: "A saved description\n설명")
            try state.start()
            try state.setTranscription(true, at: 120)
            try state.setAudioRecording(false, at: 480)
            try state.end(at: 960)
            let session = try SessionManifest(state: state, createdAt: createdAt, isDraft: false)
            try JSONEncoder().encode(session).write(to: directory.appendingPathComponent("session.json"))
        }
        return try RecordingLibrary.item(at: directory)
    }

    private func contents(of directory: URL) throws -> [String: Data] {
        var files: [String: Data] = [:]
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        {
            if try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
                for (path, data) in try contents(of: url) { files[url.lastPathComponent + "/" + path] = data }
            } else {
                files[url.lastPathComponent] = try Data(contentsOf: url)
            }
        }
        return files
    }

    private func noStaging(in directory: URL) throws -> Bool {
        try !FileManager.default.contentsOfDirectory(atPath: directory.path).contains {
            $0.hasSuffix(".staging")
        }
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("session-export-\(UUID().uuidString)")
    }
}

private final class ExportRacePresenter: NSObject, NSFilePresenter, @unchecked Sendable {
    private struct State {
        var invoked = false
        var failure: (any Error)?
    }
    private let state = Mutex(State())
    private let mutation: @Sendable () throws -> Void
    let presentedItemURL: URL?
    let presentedItemOperationQueue: OperationQueue
    var invoked: Bool { state.withLock { $0.invoked } }
    var failure: (any Error)? { state.withLock { $0.failure } }

    init(url: URL, mutation: @escaping @Sendable () throws -> Void) {
        presentedItemURL = url
        self.mutation = mutation
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        presentedItemOperationQueue = queue
        super.init()
    }

    func relinquishPresentedItem(toWriter writer: @escaping @Sendable ((@Sendable () -> Void)?) -> Void) {
        applyMutation()
        writer(nil)
    }

    func accommodatePresentedItemDeletion(completionHandler: @escaping @Sendable ((any Error)?) -> Void) {
        applyMutation()
        completionHandler(nil)
    }

    private func applyMutation() {
        let shouldRun = state.withLock { state in
            guard !state.invoked else { return false }
            state.invoked = true
            return true
        }
        guard shouldRun else { return }
        do { try mutation() } catch { state.withLock { $0.failure = error } }
    }
}
