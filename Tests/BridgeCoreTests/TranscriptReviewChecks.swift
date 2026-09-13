import BridgeCore
import Darwin
import Foundation
import RecorderKit
import TranscriptKit

struct TranscriptReviewChecks {
    func fifoMetadataIsRejectedWithoutBlocking() async throws {
        for metadata in ["session.json", "manifest.json", "transcript.json"] {
            for mode in ["open", "commit"] {
                let root = try temporaryRoot()
                defer { try? FileManager.default.removeItem(at: root) }
                let child = Process()
                child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
                child.arguments = ["--journal-fifo-probe", metadata, mode]
                var environment = ProcessInfo.processInfo.environment
                environment["SWITCHBOARD_FIFO_TEST_ROOT"] = root.path
                child.environment = environment
                child.standardOutput = FileHandle.nullDevice
                let errors = Pipe()
                child.standardError = errors
                try child.run()
                defer { if child.isRunning { _ = kill(child.processIdentifier, SIGKILL) } }
                let clock = ContinuousClock()
                let deadline = clock.now.advanced(by: .seconds(5))
                while child.isRunning, clock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
                let timedOut = child.isRunning
                if timedOut {
                    _ = kill(child.processIdentifier, SIGKILL)
                    let killedDeadline = clock.now.advanced(by: .seconds(1))
                    while child.isRunning, clock.now < killedDeadline {
                        try await Task.sleep(for: .milliseconds(10))
                    }
                }
                guard !timedOut else {
                    throw CheckFailure(description: "FIFO \(metadata) \(mode) blocked beyond five seconds")
                }
                let diagnostic = String(
                    decoding: errors.fileHandleForReading.readDataToEndOfFile().prefix(2048), as: UTF8.self)
                guard child.terminationStatus == 0 else {
                    throw CheckFailure(
                        description: "FIFO \(metadata) \(mode) was not rejected: \(diagnostic)")
                }
            }
        }
    }

    static func runFIFOProbeIfRequested() async -> Bool {
        guard CommandLine.arguments.dropFirst().first == "--journal-fifo-probe" else { return false }
        do {
            guard CommandLine.arguments.count == 4,
                ["session.json", "manifest.json", "transcript.json"].contains(CommandLine.arguments[2]),
                ["open", "commit"].contains(CommandLine.arguments[3]),
                let path = ProcessInfo.processInfo.environment["SWITCHBOARD_FIFO_TEST_ROOT"]
            else { throw CheckFailure(description: "invalid FIFO probe arguments") }
            let root = URL(fileURLWithPath: path, isDirectory: true)
            let prefix = "transcript-review-"
            guard root.lastPathComponent.hasPrefix(prefix),
                UUID(uuidString: String(root.lastPathComponent.dropFirst(prefix.count))) != nil,
                root.deletingLastPathComponent().resolvingSymlinksInPath().path
                    == FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path,
                try root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true,
                try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty
            else { throw CheckFailure(description: "FIFO fixture is not a fresh owned temporary directory") }
            let metadata = CommandLine.arguments[2]
            let fifo = root.appendingPathComponent(metadata)
            let sessionID = UUID()
            var journal: TranscriptJournal?
            var token: TranscriptSessionToken?
            if CommandLine.arguments[3] == "commit" {
                let opened = try TranscriptJournal(sessionID: sessionID, directory: root)
                let generation = await opened.beginGeneration()
                _ = try await opened.upsert(
                    TranscriptEntry(
                        side: .caller, startFrame: 0, endFrame: 1, original: "Original", isFinal: true),
                    token: generation)
                journal = opened
                token = generation
                if metadata == "transcript.json" { try FileManager.default.removeItem(at: fifo) }
            }
            guard mkfifo(fifo.path, 0o600) == 0 else {
                throw CheckFailure(description: "could not create owned FIFO")
            }
            var rejected = false
            do {
                if let journal, let token {
                    _ = try await journal.upsert(
                        TranscriptEntry(
                            side: .caller, startFrame: 1, endFrame: 2, original: "Later", isFinal: true),
                        token: token)
                } else {
                    _ = try TranscriptJournal(sessionID: sessionID, directory: root)
                }
            } catch { rejected = true }
            var attributes = stat()
            guard rejected, lstat(fifo.path, &attributes) == 0,
                attributes.st_mode & mode_t(S_IFMT) == mode_t(S_IFIFO)
            else { throw CheckFailure(description: "FIFO metadata was consumed or replaced") }
            exit(EXIT_SUCCESS)
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }

    @MainActor func offRevokesStartupWhileJournalInitializationIsSuspended() async throws {
        for cancelTask in [false, true] {
            let root = try temporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let fixture = try StartupFixture()
            let gate = TranscriptStartupGate()
            let authorization = gate.begin(context: fixture.context)
            let queue = AsyncSerialQueue(label: "transcript-startup-check.journal")
            let entered = AsyncStream<Void>.makeStream()
            let release = DispatchSemaphore(value: 0)
            defer { release.signal() }
            let sessionID = fixture.session.id
            let startup = Task { @MainActor in
                defer { entered.continuation.finish() }
                _ = try await gate.wait(authorization, context: { fixture.context }) {
                    try await queue.run {
                        let journal = try TranscriptJournal(sessionID: sessionID, directory: root)
                        entered.continuation.yield(())
                        guard release.wait(timeout: .now() + 3) == .success else {
                            throw CheckFailure(description: "journal gate timed out")
                        }
                        return journal
                    }
                }
                try gate.require(authorization, context: fixture.context)
                if gate.permits(authorization, context: fixture.context) {
                    try fixture.session.setTranscription(true, at: 20)
                    fixture.activations += 1
                }
            }
            var didEnter = false
            for await _ in entered.stream {
                didEnter = true
                break
            }
            try expect(didEnter)
            let revision = gate.invalidate()
            if cancelTask { startup.cancel() }
            try fixture.session.setTranscription(false, at: 10)
            release.signal()
            var cancelled = false
            do { try await startup.value } catch is CancellationError { cancelled = true }
            try expect(cancelled && fixture.activations == 0 && !fixture.session.transcription)
            try expect(
                fixture.session.transcriptionIntervals == [interval(0, 10)]
                    && fixture.session.durationFrames == 10)
            try expect(gate.isCurrentRevocation(revision))
        }
    }

    @MainActor func presentationChangesRevokeUncancelledStartup() async throws {
        let fixture = try StartupFixture()
        let gate = TranscriptStartupGate()
        let authorization = gate.begin(context: fixture.context)
        do {
            _ = try await gate.wait(
                authorization, context: { fixture.context },
                operation: {
                    fixture.presentation = UUID()
                    return 1
                })
            throw CheckFailure(description: "changed presentation kept startup authorization")
        } catch is CancellationError {}
        try expect(!gate.permits(authorization, context: fixture.context))
        let stopped = gate.invalidate()
        _ = gate.begin(context: fixture.context)
        try expect(!gate.isCurrentRevocation(stopped))
    }

    func offReconciliationPreservesTheOriginalBoundaryAndRecording() throws {
        var state = try SessionState(name: "Cancelled activation")
        try state.start(at: 0)
        try state.setTranscription(true, at: 0)
        try state.setTranscription(false, at: 10)
        try state.setTranscription(true, at: 20)
        try state.advance(to: 30)
        let audio = state.recordingIntervals
        try state.reconcileTranscriptionOff(at: 10)
        try expect(!state.transcription && state.transcriptionIntervals == [interval(0, 10)])
        try expect(state.durationFrames == 30 && state.recordingIntervals == audio)
        let corrected = state
        try state.reconcileTranscriptionOff(at: 10)
        try expect(state == corrected)
    }
    func journalRejectsAReplacementDirectoryWithoutChangingEitherArchive() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("Session")
        let first = try await journalFixture(at: destination, text: "First session")
        let originalBytes = try bytes(destination)
        let moved = root.appendingPathComponent("Moved session")
        try FileManager.default.moveItem(at: destination, to: moved)
        _ = try await journalFixture(at: destination, text: "Replacement session")
        let replacementBytes = try bytes(destination)
        try await rejects {
            _ = try await first.journal.upsert(entry("Late original", start: 4, end: 5), token: first.token)
        }
        try expect(bytes(destination) == replacementBytes)
        try expect(bytes(moved) == originalBytes)
    }

    func journalRechecksSessionAndAudioMetadataIdentity() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["session.json", "manifest.json"] {
            let directory = root.appendingPathComponent(name + "-case")
            let fixture = try await journalFixture(at: directory, text: "Owned session")
            let original = try bytes(directory)
            let otherID = UUID()
            if name == "session.json" {
                var state = try SessionState(id: otherID, name: "Other owner")
                try state.start(at: 0)
                try state.end(at: 30)
                try JSONEncoder().encode(SessionManifest(state: state, isDraft: false)).write(
                    to: directory.appendingPathComponent(name))
            } else {
                try RecordingManifest(id: otherID, title: "Other owner", owner: .manual).save(to: directory)
            }
            let changed = try Data(contentsOf: directory.appendingPathComponent(name))
            try await rejects { _ = try await fixture.journal.recordGap(gap(4, 5), token: fixture.token) }
            try expect(bytes(directory) == original)
            try expect(Data(contentsOf: directory.appendingPathComponent(name)) == changed)
        }
    }

    func packageAndAncestorSymlinksCannotRedirectJournalWrites() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let firstDirectory = root.appendingPathComponent("Original")
        let first = try await journalFixture(at: firstDirectory, text: "Original")
        let originalBytes = try bytes(firstDirectory)
        let replacementDirectory = root.appendingPathComponent("Replacement")
        _ = try await journalFixture(at: replacementDirectory, text: "Replacement")
        let replacementBytes = try bytes(replacementDirectory)
        let moved = root.appendingPathComponent("Moved")
        try FileManager.default.moveItem(at: firstDirectory, to: moved)
        try FileManager.default.createSymbolicLink(
            at: firstDirectory, withDestinationURL: replacementDirectory)
        try await rejects {
            _ = try await first.journal.upsert(entry("Late", start: 4, end: 5), token: first.token)
        }
        try expect(bytes(replacementDirectory) == replacementBytes && bytes(moved) == originalBytes)

        let parentA = root.appendingPathComponent("Parent A")
        let parentB = root.appendingPathComponent("Parent B")
        let a = try await journalFixture(
            at: parentA.appendingPathComponent("Session"), text: "Alias original")
        _ = try await journalFixture(at: parentB.appendingPathComponent("Session"), text: "Alias replacement")
        let alias = root.appendingPathComponent("Alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: parentA)
        let aliasJournal = try TranscriptJournal(
            sessionID: a.id, directory: alias.appendingPathComponent("Session"))
        let token = await aliasJournal.beginGeneration()
        let aBytes = try bytes(parentA.appendingPathComponent("Session"))
        let bBytes = try bytes(parentB.appendingPathComponent("Session"))
        try FileManager.default.removeItem(at: alias)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: parentB)
        try await rejects { _ = try await aliasJournal.recordGap(gap(4, 5), token: token) }
        try expect(bytes(parentA.appendingPathComponent("Session")) == aBytes)
        try expect(bytes(parentB.appendingPathComponent("Session")) == bBytes)
    }

    func newLiveGapSurvivesLaterFinalsAndRemainsReplayable() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try liveMetadata(at: root, enabledThrough: 30)
        let journal = try TranscriptJournal(sessionID: fixture.session.id, directory: root)
        try await journal.setConfiguration(configuration())
        let token = await journal.beginGeneration()
        try check(await journal.prepareCheckpoints(durationFrames: 30, token: token))
        let feeds = TranscriptFeeds(maximumBufferedPackets: 2)
        try expect(feeds.append(side: .caller, samples: [Float](repeating: 0, count: 20), startFrame: 0))
        try expect(feeds.append(side: .caller, samples: [Float](repeating: 0, count: 36), startFrame: 12))
        try check(await journal.recordGap(gap(10, 12), token: token))
        try check(
            await journal.upsert(entry("One final spanning lost input", start: 0, end: 25), token: token))
        let completion = drained(feeds)
        try check(
            await journal.commitLiveDelivery(
                feeds.deliveryReceipt(), completion: completion, recording: fixture.audio,
                session: fixture.session, throughFrame: 30, token: token))
        let reopened = try TranscriptJournal(sessionID: fixture.session.id, directory: root)
        let checkpoints = await reopened.completedThrough()
        try expect(checkpoints[.caller] == 10)
        let progress = try await StoredTranscriptProcessor.progress(
            item: RecordingItem(directory: root, manifest: fixture.audio))
        try expect(progress.remainingIntervals[.caller] == [interval(10, 2), interval(25, 5)])
        try check(await reopened.gaps() == [gap(10, 12)])
        try check(await reopened.snapshot().count == 1)

        let unrecordedRoot = root.appendingPathComponent("unrecorded")
        try FileManager.default.createDirectory(at: unrecordedRoot, withIntermediateDirectories: false)
        let unrecorded = try liveMetadata(
            at: unrecordedRoot, enabledThrough: 30, recordingGap: interval(10, 2))
        let offJournal = try TranscriptJournal(sessionID: unrecorded.session.id, directory: unrecordedRoot)
        try await offJournal.setConfiguration(configuration())
        let offToken = await offJournal.beginGeneration()
        try check(await offJournal.prepareCheckpoints(durationFrames: 30, token: offToken))
        try check(await offJournal.recordGap(gap(10, 12), token: offToken))
        try check(
            await offJournal.commitLiveDelivery(
                feeds.deliveryReceipt(), completion: completion, recording: unrecorded.audio,
                session: unrecorded.session, throughFrame: 30, token: offToken))
        let offProgress = try await StoredTranscriptProcessor.progress(
            item: RecordingItem(directory: unrecordedRoot, manifest: unrecorded.audio))
        try expect(offProgress.completedThrough[.caller] == 30 && !offProgress.hasWork)
        try check(await offJournal.gaps() == [gap(10, 12)])
    }

    func fullyDeliveredSilenceHasNoPermanentPendingWork() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try liveMetadata(at: root, enabledThrough: 30)
        let journal = try TranscriptJournal(sessionID: fixture.session.id, directory: root)
        try await journal.setConfiguration(configuration())
        let token = await journal.beginGeneration()
        try check(await journal.prepareCheckpoints(durationFrames: 30, token: token))
        let feeds = TranscriptFeeds()
        try expect(feeds.append(side: .caller, samples: [Float](repeating: 0, count: 60), startFrame: 0))
        try check(
            await journal.commitLiveDelivery(
                feeds.deliveryReceipt(), completion: drained(feeds), recording: fixture.audio,
                session: fixture.session, throughFrame: 30, token: token))
        let progress = try await StoredTranscriptProcessor.progress(
            item: RecordingItem(directory: root, manifest: fixture.audio))
        try expect(progress.completedThrough[.caller] == 30)
        try expect(!progress.hasWork && progress.remainingIntervals.values.allSatisfy(\.isEmpty))
    }

    func liveProgressClipsAtOffBoundaryBeforeDrainLatency() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try liveMetadata(at: root, enabledThrough: 20)
        let journal = try TranscriptJournal(sessionID: fixture.session.id, directory: root)
        try await journal.setConfiguration(configuration())
        let token = await journal.beginGeneration()
        try check(await journal.prepareCheckpoints(durationFrames: 30, token: token))
        let feeds = TranscriptFeeds()
        try expect(feeds.append(side: .caller, samples: [Float](repeating: 0, count: 60), startFrame: 0))
        try check(
            await journal.commitLiveDelivery(
                feeds.deliveryReceipt(), completion: drained(feeds), recording: fixture.audio,
                session: fixture.session, throughFrame: 20, token: token))
        try check(await journal.completedThrough()[.caller] == 20)
        let progress = try await StoredTranscriptProcessor.progress(
            item: RecordingItem(directory: root, manifest: fixture.audio))
        try expect(progress.remainingIntervals.values.allSatisfy(\.isEmpty))
        try expect(RecordingManifest.load(from: root).durationFrames == 30)
    }

    func onlyActuallyEnqueuedInputContributesToDeliveryEvidence() async throws {
        let feeds = TranscriptFeeds(maximumBufferedPackets: 1)
        try expect(feeds.append(side: .caller, samples: [Float](repeating: 0, count: 8), startFrame: 0))
        try expect(!feeds.append(side: .caller, samples: [Float](repeating: 0, count: 8), startFrame: 4))
        let pending = Task {
            await feeds.appendRecorded(side: .caller, samples: [Float](repeating: 0, count: 8), startFrame: 8)
        }
        feeds.finish()
        try check(!(await pending.value))
        let receipt = feeds.deliveryReceipt()
        try expect(receipt.acceptedThrough[.caller] == 4 && receipt.intervals[.caller] == [interval(0, 4)])
        try expect(receipt.acceptedThrough[.agent] == nil)
    }

    func successfulStopAndTransientFailureKeepUnchangedLanguagesStartable() throws {
        let configuration = try configuration()
        let installed: [AudioSide: TranscriptSideState] = [
            .caller: TranscriptSideState(side: .caller, speech: .ready, translation: .notNeeded)
        ]
        var policy = TranscriptReadinessState()
        policy.updateCapabilities(installed, configuration: configuration)
        let completion = TranscriptCompletion(finalizedSources: [.caller], states: installed)
        guard let stopped = completion.states[.caller] else {
            throw CheckFailure(description: "missing real stopped state")
        }
        try expect(stopped.speech == .stopped)
        policy.observeRunState(stopped, configuration: configuration)
        try expect(policy.canStart(configuration: configuration, busy: false, stopping: false))
        policy.observeRunState(
            TranscriptSideState(side: .caller, speech: .resourceLimit, translation: .notNeeded),
            configuration: configuration)
        try expect(policy.canStart(configuration: configuration, busy: false, stopping: false))
        try expect(!policy.canStart(configuration: configuration, busy: false, stopping: true))
        policy.updateCapabilities(
            [.caller: TranscriptSideState(side: .caller, speech: .downloadRequired, translation: .notNeeded)],
            configuration: configuration)
        try expect(!policy.canStart(configuration: configuration, busy: false, stopping: false))
    }

    func selectingNewSessionClearsOldTextBeforeAnyEngineStart() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try await journalFixture(at: root.appendingPathComponent("A"), text: "Session A text")
        var state = TranscriptPresentationState()
        let selectionA = state.select(sessionID: first.id, archived: true)
        let savedA = try TranscriptJournal.readArchive(sessionID: first.id, directory: first.directory)
        try expect(state.apply(savedA, selection: selectionA) && !state.entries.isEmpty)
        let idB = UUID()
        state.select(sessionID: idB)
        try expect(
            state.sessionID == idB && state.entries.isEmpty && state.gaps.isEmpty && state.error == nil)
        try expect(state.showConfiguration && state.archiveConfiguration == nil)
        try expect(!state.apply(savedA, selection: selectionA) && state.entries.isEmpty)
    }

    func archivedPresentationLoadsItsOwnTextReadOnlyAndRejectsLateSelection() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try await journalFixture(at: root.appendingPathComponent("A"), text: "A own text")
        let second = try await journalFixture(at: root.appendingPathComponent("B"), text: "B own text")
        let firstBytes = try bytes(first.directory)
        let secondBytes = try bytes(second.directory)
        var state = TranscriptPresentationState()
        let selectionA = state.select(sessionID: first.id, archived: true)
        let selectionB = state.select(sessionID: second.id, archived: true)
        let savedA = try TranscriptJournal.readArchive(sessionID: first.id, directory: first.directory)
        let savedB = try TranscriptJournal.readArchive(sessionID: second.id, directory: second.directory)
        try expect(!state.apply(savedA, selection: selectionA))
        try expect(state.apply(savedB, selection: selectionB))
        try expect(state.entries.map(\.original) == ["B own text"] && !state.showConfiguration)
        try expect(bytes(first.directory) == firstBytes && bytes(second.directory) == secondBytes)
        try expectThrows {
            _ = try TranscriptJournal.readArchive(sessionID: second.id, directory: first.directory)
        }
    }

    private struct JournalFixture {
        let id: UUID
        let directory: URL
        let journal: TranscriptJournal
        let token: TranscriptSessionToken
    }

    private func journalFixture(at directory: URL, text: String) async throws -> JournalFixture {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = UUID()
        let journal = try TranscriptJournal(sessionID: id, directory: directory)
        try await journal.setConfiguration(configuration())
        let token = await journal.beginGeneration()
        _ = try await journal.upsert(entry(text, start: 0, end: 3), token: token)
        return JournalFixture(id: id, directory: directory, journal: journal, token: token)
    }

    private func liveMetadata(at directory: URL, enabledThrough: Int64, recordingGap: SessionInterval? = nil)
        throws -> (
            session: SessionManifest, audio: RecordingManifest
        )
    {
        var state = try SessionState(name: "Live checkpoint")
        try state.start(at: 0)
        try state.setTranscription(true, at: 0)
        if let recordingGap {
            try state.setAudioRecording(false, at: recordingGap.startFrame)
            try state.setAudioRecording(true, at: recordingGap.endFrame)
        }
        try state.setTranscription(false, at: enabledThrough)
        try state.end(at: 30)
        let session = try SessionManifest(state: state, isDraft: false)
        var audio = RecordingManifest(
            id: session.id, title: session.title, createdAt: session.createdAt, owner: .manual)
        audio.durationFrames = 30
        audio.segments = [RecordingSegment(side: .caller, filename: "caller.caf", startFrame: 0, frames: 30)]
        if let recordingGap {
            audio.segments = [
                RecordingSegment(
                    side: .caller, filename: "caller-before.caf", startFrame: 0,
                    frames: recordingGap.startFrame),
                RecordingSegment(
                    side: .caller, filename: "caller-after.caf", startFrame: recordingGap.endFrame,
                    frames: 30 - recordingGap.endFrame),
            ]
        }
        try audio.save(to: directory)
        try JSONEncoder().encode(session).write(to: directory.appendingPathComponent("session.json"))
        return (session, audio)
    }

    private func drained(_ feeds: TranscriptFeeds) -> TranscriptCompletion {
        feeds.finish()
        return TranscriptCompletion(
            finalizedSources: [.caller],
            states: [.caller: TranscriptSideState(side: .caller, speech: .ready, translation: .notNeeded)],
            delivery: feeds.deliveryReceipt())
    }

    private func configuration() throws -> TranscriptConfiguration {
        try TranscriptConfiguration(
            callerLocaleIdentifier: "en-US", agentLocaleIdentifier: "en-US", targetLocaleIdentifier: "en-US")
    }

    private func entry(_ text: String, start: Int64, end: Int64) -> TranscriptEntry {
        TranscriptEntry(side: .caller, startFrame: start, endFrame: end, original: text, isFinal: true)
    }
    private func gap(_ start: Int64, _ end: Int64) -> TranscriptGap {
        TranscriptGap(side: .caller, startFrame: start, endFrame: end, reason: "input lost before delivery")
    }
    private func interval(_ start: Int64, _ frames: Int64) throws -> SessionInterval {
        try SessionInterval(startFrame: start, frames: frames)
    }
    private func bytes(_ directory: URL) throws -> Data {
        try Data(contentsOf: directory.appendingPathComponent("transcript.json"))
    }
    private func check(_ value: Bool) throws { try expect(value) }
    private func rejects(_ operation: () async throws -> Void) async throws {
        var rejected = false
        do { try await operation() } catch { rejected = true }
        try expect(rejected)
    }
    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "transcript-review-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

@MainActor private final class StartupFixture {
    var operation = UUID()
    var presentation = UUID()
    var session: SessionState
    var activations = 0
    var context: TranscriptStartupContext {
        TranscriptStartupContext(operation: operation, presentation: presentation, sessionID: session.id)
    }
    init() throws {
        session = try SessionState(name: "Resumed session")
        try session.start(at: 0)
        try session.setTranscription(true, at: 0)
    }
}
