import BridgeCore
import Foundation
import Observation
import RecorderKit
import TranscriptKit

private struct SessionPresentation: Equatable {
    let id: UUID?
    let name: String
    let description: String
    let running: Bool
    let paused: Bool
    let active: Bool
    let recording: Bool
    let audioRecordingEnabled: Bool
    let transcriptionEnabled: Bool
    let pauseReason: SessionPauseReason?

    init(state: SessionState?, closed: Bool) {
        id = state?.id
        name = state?.name ?? ""
        description = state?.description ?? ""
        running = state?.lifecycle == .running
        paused = state?.lifecycle == .paused
        active = state != nil && !closed
        recording = state?.effectiveAudioRecording == true
        audioRecordingEnabled = state?.audioRecording == true
        transcriptionEnabled = state?.transcription == true
        pauseReason = state?.pauseReason
    }
}

@MainActor @Observable final class SessionController {
    let pipeline = AudioPipeline()
    private let files = AsyncSerialQueue(label: "com.switchboard.main.sessions", qos: .utility)
    private let store: SessionStore
    private(set) var state: SessionState? {
        didSet { updatePresentation() }
    }
    private(set) var directory: URL?
    private(set) var createdAt = Date.now
    private(set) var busy = false
    private(set) var closed = false {
        didSet { updatePresentation() }
    }
    private var presentation = SessionPresentation(state: nil, closed: false)
    private var pendingOperations = 0
    private var transition: Task<Void, Never>?
    private var checkpointTask: Task<Void, Never>?
    private var quitting = false
    private var endFrame: Int64?
    var error: Error?

    // Controls and headings observe only semantic changes, independently of the precise session clock.
    var hasSession: Bool { presentation.id != nil }
    var sessionID: UUID? { presentation.id }
    var sessionName: String { presentation.name }
    var sessionDescription: String { presentation.description }
    var running: Bool { presentation.running }
    var paused: Bool { presentation.paused }
    var active: Bool { presentation.active }
    var recording: Bool { presentation.recording }
    var audioRecordingEnabled: Bool { presentation.audioRecordingEnabled }
    var transcriptionEnabled: Bool { presentation.transcriptionEnabled }
    var pauseReason: SessionPauseReason? { presentation.pauseReason }
    var duration: Double { Double(state?.durationFrames ?? 0) / 48_000 }

    init(draftRoot: URL) { store = SessionStore(draftRoot: draftRoot) }

    private func updatePresentation() {
        let next = SessionPresentation(state: state, closed: closed)
        if next != presentation { presentation = next }
    }

    func showPreview(id: UUID = UUID(), name: String, description: String) throws {
        guard state == nil, directory == nil else { return }
        var preview = try SessionState(id: id, name: name, description: description)
        try preview.start(at: 0)
        state = preview
    }
    func closePreview() {
        guard directory == nil else { return }
        state = nil
    }

    private func perform<T: Sendable>(_ operation: @MainActor @escaping () async throws -> T) async throws
        -> T
    {
        guard !quitting else { throw CancellationError() }
        let previous = transition
        pendingOperations += 1
        busy = true
        let task = Task { @MainActor in
            await previous?.value
            return try await operation()
        }
        transition = Task { _ = try? await task.value }
        defer {
            pendingOperations -= 1
            busy = pendingOperations > 0
        }
        return try await task.value
    }

    func start(id: UUID = UUID(), name: String, description: String) async throws {
        try await perform { [self] in
            guard state == nil else { return }
            var next = try SessionState(id: id, name: name, description: description)
            try next.start(at: 0)
            let date = Date.now
            let metadata = try SessionManifest(state: next, createdAt: date)
            let store = store
            let draft = try await files.run { try store.createDraft(metadata) }
            try await pipeline.startSession(
                directory: draft,
                manifest: RecordingManifest(id: next.id, title: next.name, createdAt: date, owner: .manual))
            state = next
            directory = draft
            createdAt = date
            closed = false
            endFrame = nil
        }
    }

    func savedDrafts() async throws -> [StoredSession] {
        let store = store
        return try await files.run { try store.drafts() }
    }

    func restoreDraft(_ draft: StoredSession) async throws {
        try await perform { [self] in
            guard state == nil else { throw SessionStateError.invalidTransition }
            let store = store
            let recovered = try await files.run {
                let metadata = try store.load(at: draft.directory)
                guard metadata.id == draft.manifest.id, metadata.createdAt == draft.manifest.createdAt else {
                    throw SessionStoreError.identityMismatch
                }
                let audio = try RecordingManifest.load(from: draft.directory)
                guard audio.id == metadata.id, audio.createdAt == metadata.createdAt else {
                    throw SessionStoreError.identityMismatch
                }
                let item = try RecordingLibrary.recover(
                    RecordingItem(directory: draft.directory, manifest: audio))
                let state = try metadata.state.recovered(
                    durationFrames: max(metadata.durationFrames, item.manifest.durationFrames))
                let next = try SessionManifest(state: state, createdAt: metadata.createdAt)
                try store.update(next, at: draft.directory)
                return next
            }
            state = recovered.state
            directory = draft.directory
            createdAt = recovered.createdAt
            closed = true
        }
    }

    func updateElapsed(_ seconds: Double) {
        guard !busy, !closed, endFrame == nil, var next = state, seconds.isFinite, seconds >= 0,
            seconds * 48_000 < Double(Int64.max)
        else { return }
        do {
            let frame = Int64(seconds * 48_000)
            guard frame > next.durationFrames else { return }
            try next.advance(to: frame)
            state = next
        } catch { self.error = error }
    }

    func pause(reason: SessionPauseReason = .manual) async throws {
        try await perform { [self] in
            guard !closed, var next = state, next.lifecycle == .running else { return }
            let frame = await pipeline.setControls(relaying: false, recording: false)
            try next.pause(at: max(frame, next.durationFrames), reason: reason)
            state = next
            _ = try await pipeline.checkpoint(durationFrames: next.durationFrames)
            try await persist()
        }
    }

    func resume() async throws {
        try await perform { [self] in
            guard !closed, var next = state, next.lifecycle == .paused else { return }
            endFrame = nil
            let frame = await pipeline.setControls(
                relaying: true, recording: next.audioRecording)
            try next.resume(at: max(frame, next.durationFrames))
            state = next
            try await persist()
        }
    }

    func setRecording(_ enabled: Bool) async throws {
        try await perform { [self] in
            guard !closed, var next = state else { return }
            let frame = await pipeline.setControls(relaying: running, recording: enabled)
            try next.setAudioRecording(enabled, at: max(frame, next.durationFrames))
            state = next
            if !enabled { _ = try await pipeline.checkpoint(durationFrames: next.durationFrames) }
            try await persist()
        }
    }

    @discardableResult func setTranscription(
        _ enabled: Bool, authorized: @MainActor @escaping () -> Bool = { true }
    ) async throws -> Int64? {
        return try await perform { [self] in
            guard !closed, var next = state else { return nil }
            let frame = await pipeline.currentSessionFrame()
            guard !enabled || authorized() else { throw CancellationError() }
            try next.setTranscription(enabled, at: max(frame, next.durationFrames))
            state = next
            try await persist()
            return next.durationFrames
        }
    }

    func reconcileTranscriptionOff(at frame: Int64, sessionID: UUID) async throws {
        try await perform { [self] in
            guard !closed, var next = state, next.id == sessionID, next.transcription else { return }
            try next.reconcileTranscriptionOff(at: frame)
            state = next
            try await persist()
        }
    }

    func prepareToEnd() async throws {
        try await pause()
        endFrame = state?.durationFrames
    }
    func cancelEnd() { endFrame = nil }

    func checkpoint() {
        guard active, !busy, endFrame == nil, checkpointTask == nil else { return }
        checkpointTask = Task { [weak self] in
            guard let self else { return }
            defer { checkpointTask = nil }
            do { try await persist() } catch { self.error = error }
        }
    }

    private func persist() async throws {
        guard let state, let directory else { return }
        let metadata = try SessionManifest(state: state, createdAt: createdAt, isDraft: true)
        let store = store
        let result = await files.complete { Result { try store.update(metadata, at: directory) } }
        try result.get()
    }

    // All callers hold the transition slot. Save-panel cancellation occurs before this terminal operation.
    private func close() async throws {
        guard !closed, var next = state else { return }
        await checkpointTask?.value
        let stoppedAt = await pipeline.setControls(relaying: false, recording: false)
        let frame = endFrame ?? max(stoppedAt, next.durationFrames)
        var failure: Error?
        var audioEnd = frame
        do {
            let audioDirectory = try await pipeline.finishSession(
                durationFrames: max(frame, next.durationFrames))
            if let audioDirectory {
                audioEnd = try await files.run {
                    try RecordingManifest.load(from: audioDirectory).durationFrames
                }
            }
        } catch { failure = error }
        try next.end(at: max(frame, max(next.durationFrames, audioEnd)))
        state = next
        closed = true
        do { try await persist() } catch { if failure == nil { failure = error } }
        if let failure { throw failure }
    }

    func save(to destination: URL, replacement: SessionReplacementAuthorization? = nil) async throws
        -> SessionPublication?
    {
        try await perform { [self] in
            guard directory != nil else { return nil }
            try await close()
            guard let directory, let state else { return nil }
            let metadata = try SessionManifest(state: state, createdAt: createdAt, isDraft: false)
            let store = store
            let result = await files.complete {
                Result {
                    _ = try RecordingRenderer.finalize(directory: directory)
                    return try store.publishClosedDraft(
                        at: directory, to: destination, manifest: metadata, replacement: replacement)
                }
            }
            let publication = try result.get()
            reset()
            return publication
        }
    }

    func discard() async throws -> URL? {
        try await perform { [self] in
            guard let directory else { return nil }
            try await close()
            reset()
            return directory
        }
    }

    @discardableResult func dismissClosed() -> Bool {
        guard closed, !busy, !quitting else { return false }
        reset()
        return true
    }

    func preserveOnQuit() async {
        quitting = true
        await transition?.value
        busy = true
        defer { busy = false }
        do { try await close() } catch { self.error = error }
        await pipeline.shutdownRoutes()
    }

    private func reset() {
        state = nil
        directory = nil
        closed = false
        endFrame = nil
    }
}
