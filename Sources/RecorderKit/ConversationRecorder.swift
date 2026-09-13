import BridgeCore
import Foundation

public struct RecorderSnapshot: Sendable {
    public var manifest: RecordingManifest?
    public var directory: URL?
    public var error: String?
    public init(manifest: RecordingManifest? = nil, directory: URL? = nil, error: String? = nil) {
        self.manifest = manifest
        self.directory = directory
        self.error = error
    }
}

public enum RecorderLifecycleError: Error, Equatable, LocalizedError, Sendable {
    case alreadyStarted, finished

    public var errorDescription: String? {
        switch self {
        case .alreadyStarted: "This recorder has already been started. Create a new recorder."
        case .finished: "This recorder has finished. Create a new recorder."
        }
    }
}

// This unchecked boundary is confined: the worker owns lifecycle, writers, failure
// decisions and snapshots. The lock owns only admission and pending bytes. No file
// operation or client callback runs under the lock; callers never wait with it held.
public final class ConversationRecorder: @unchecked Sendable {
    private enum Lifecycle {
        case ready, recording, failed
        case finished(Result<URL?, any Error>)
    }
    private enum Admission { case ready, starting, accepting, closed }

    private let worker = DispatchQueue(label: "com.switchboard.main.recorder", qos: .utility)
    private let admission = NSLock()
    private let maximumPendingBytes: Int
    private var pendingBytes = 0
    private var admissionState = Admission.ready
    private var lifecycle = Lifecycle.ready
    private var firstFailure: RecorderFailure?
    private var snapshotValue = RecorderSnapshot()
    private var writers: [AudioSide: SegmentWriter] = [:]
    private let onFailure: @Sendable (RecorderFailure) -> Void

    public init(
        maximumPendingBytes: Int = 4_194_304,
        onFailure: @escaping @Sendable (RecorderFailure) -> Void = { _ in }
    ) {
        precondition(maximumPendingBytes > 0)
        self.maximumPendingBytes = maximumPendingBytes
        self.onFailure = onFailure
    }
    public func snapshot() -> RecorderSnapshot { worker.sync { snapshotValue } }

    /// A recorder owns at most one start attempt, including a failed attempt.
    public func start(root: URL, owner: RecordingOwner) throws -> URL {
        try worker.sync {
            switch lifecycle {
            case .ready: break
            case .recording, .failed: throw RecorderLifecycleError.alreadyStarted
            case .finished: throw RecorderLifecycleError.finished
            }
            let canStart = admission.withLock {
                guard admissionState == .ready else { return false }
                admissionState = .starting
                return true
            }
            guard canStart else {
                lifecycle = .finished(.success(nil))
                throw RecorderLifecycleError.finished
            }
            do {
                let id = UUID()
                let directory = root.appendingPathComponent(
                    id.uuidString + ".mihrecording", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let title = Date.now.formatted(date: .abbreviated, time: .shortened)
                let manifest = RecordingManifest(id: id, title: title, owner: owner)
                try manifest.save(to: directory)
                snapshotValue = RecorderSnapshot(manifest: manifest, directory: directory)
                for side in AudioSide.allCases {
                    writers[side] = SegmentWriter(side: side, directory: directory)
                }
                lifecycle = .recording
                admission.withLock {
                    // A concurrent finish may have closed admission while files were created.
                    if admissionState == .starting { admissionState = .accepting }
                }
                return directory
            } catch {
                lifecycle = .failed
                admission.withLock { admissionState = .closed }
                snapshotValue.error = error.localizedDescription
                throw error
            }
        }
    }

    public func append(side: AudioSide, samples: [Float], frame: Int64) -> Bool {
        admission.lock()
        defer { admission.unlock() }
        guard admissionState == .accepting else { return false }
        let frames = Int64(samples.count / 2)
        let (end, overflow) = frame.addingReportingOverflow(frames)
        // Every queued block consumes at least one stereo frame of the byte budget.
        let valid = frame >= 0 && !overflow && !samples.isEmpty && samples.count.isMultiple(of: 2)
        guard valid, samples.count <= (maximumPendingBytes - pendingBytes) / MemoryLayout<Float>.size else {
            admissionState = .closed
            let failure = RecorderFailure(valid ? MediaFailure.overrun : MediaFailure.invalidBuffer)
            worker.async { [self] in
                guard var manifest = snapshotValue.manifest else { return }
                if valid, frames > 0 {
                    manifest.durationFrames = max(manifest.durationFrames, end)
                    manifest.gaps.append(
                        AudioGap(
                            side: side, startFrame: frame, frames: frames,
                            reason: "recording queue overflow"))
                }
                fail(failure, manifest: &manifest)
            }
            return false
        }
        let bytes = samples.count * MemoryLayout<Float>.size
        pendingBytes += bytes
        // Enqueue while admission is locked so finish cannot overtake an accepted block.
        worker.async { [self] in
            defer { admission.withLock { pendingBytes -= bytes } }
            guard case .recording = lifecycle, var manifest = snapshotValue.manifest,
                let writer = writers[side]
            else { return }
            do {
                try writer.append(samples, at: frame, manifest: &manifest)
                snapshotValue.manifest = manifest
            } catch {
                fail(RecorderFailure(error), manifest: &manifest)
            }
        }
        return true
    }

    /// Closes admission permanently, drains accepted blocks and replays the first finish result.
    public func finish(durationFrames: Int64) throws -> URL? {
        admission.withLock { admissionState = .closed }
        return try worker.sync {
            if case .finished(let result) = lifecycle { return try result.get() }
            guard var manifest = snapshotValue.manifest, let directory = snapshotValue.directory else {
                lifecycle = .finished(.success(nil))
                return nil
            }
            var closeError: (any Error)?
            for writer in writers.values {
                do { try writer.close(manifest: &manifest) } catch {
                    if closeError == nil { closeError = error }
                }
            }
            writers.removeAll()
            manifest.durationFrames = max(durationFrames, manifest.durationFrames)
            do {
                if let closeError { throw closeError }
                for side in AudioSide.allCases {
                    let end =
                        manifest.segments.filter { $0.side == side }.map { $0.startFrame + $0.frames }.max()
                        ?? 0
                    let alreadyRecorded = manifest.gaps.contains {
                        $0.side == side && $0.startFrame <= end
                            && $0.startFrame + $0.frames >= manifest.durationFrames
                    }
                    if end < manifest.durationFrames, !alreadyRecorded {
                        manifest.gaps.append(
                            AudioGap(
                                side: side, startFrame: end, frames: manifest.durationFrames - end,
                                reason: "source unavailable"))
                    }
                }
                if manifest.status != .failed { manifest.status = .finalizing }
                try manifest.save(to: directory)
                snapshotValue.manifest = manifest
                lifecycle = .finished(.success(directory))
                return directory
            } catch {
                fail(RecorderFailure(error), manifest: &manifest)
                lifecycle = .finished(.failure(error))
                throw error
            }
        }
    }

    /// Called only on worker. Notifications leave that queue to allow safe client callbacks.
    private func fail(_ failure: RecorderFailure, manifest: inout RecordingManifest) {
        admission.withLock { admissionState = .closed }
        lifecycle = .failed
        let shouldNotify = firstFailure == nil
        let original = firstFailure ?? failure
        firstFailure = original
        let message = original.detail
        manifest.status = .failed
        manifest.failure = message
        manifest.failureCode = original.media?.rawValue
        snapshotValue.manifest = manifest
        snapshotValue.error = message
        if let directory = snapshotValue.directory {
            do { try manifest.save(to: directory) } catch { snapshotValue.error = error.localizedDescription }
        }
        if shouldNotify {
            let notify = onFailure
            DispatchQueue.global(qos: .utility).async { notify(original) }
        }
    }
}
