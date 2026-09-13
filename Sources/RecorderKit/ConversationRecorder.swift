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

// The serial worker owns files/state. The lock protects only bounded queue admission.
public final class ConversationRecorder: @unchecked Sendable {
    private let worker = DispatchQueue(label: "com.switchboard.main.recorder", qos: .utility)
    private let admission = NSLock()
    private let maximumPendingBytes: Int
    private var pendingBytes = 0
    private var accepting = false
    private var failureReported = false
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

    public func start(root: URL, owner: RecordingOwner) throws -> URL {
        try worker.sync {
            guard writers.isEmpty else { throw MediaFailure.invalidBuffer }
            let id = UUID()
            let directory = root.appendingPathComponent(id.uuidString + ".mihrecording", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let title = Date.now.formatted(date: .abbreviated, time: .shortened)
            let manifest = RecordingManifest(id: id, title: title, owner: owner)
            try manifest.save(to: directory)
            snapshotValue = RecorderSnapshot(manifest: manifest, directory: directory)
            for side in AudioSide.allCases { writers[side] = SegmentWriter(side: side, directory: directory) }
            admission.withLock {
                accepting = true
                failureReported = false
            }
            return directory
        }
    }

    public func append(side: AudioSide, samples: [Float], frame: Int64) -> Bool {
        admission.lock()
        defer { admission.unlock() }
        guard accepting else { return false }
        let frames = Int64(samples.count / 2)
        let (end, overflow) = frame.addingReportingOverflow(frames)
        let valid = frame >= 0 && !overflow && samples.count.isMultiple(of: 2)
        guard valid, samples.count <= (maximumPendingBytes - pendingBytes) / MemoryLayout<Float>.size else {
            accepting = false
            if !failureReported {
                failureReported = true
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
            }
            return false
        }
        let bytes = samples.count * MemoryLayout<Float>.size
        pendingBytes += bytes
        // Enqueue while admission is locked so finish cannot overtake an accepted block.
        worker.async { [self] in
            defer { admission.withLock { pendingBytes -= bytes } }
            guard var manifest = snapshotValue.manifest, manifest.status == .recording,
                let writer = writers[side]
            else { return }
            do {
                try writer.append(samples, at: frame, manifest: &manifest)
                snapshotValue.manifest = manifest
            } catch {
                admission.withLock { accepting = false }
                fail(RecorderFailure(error), manifest: &manifest)
            }
        }
        return true
    }

    public func finish(durationFrames: Int64) throws -> URL? {
        admission.withLock { accepting = false }
        return try worker.sync {
            guard var manifest = snapshotValue.manifest, let directory = snapshotValue.directory else {
                return nil
            }
            guard !writers.isEmpty else { return directory }
            for writer in writers.values { try writer.close(manifest: &manifest) }
            writers.removeAll()
            manifest.durationFrames = max(durationFrames, manifest.durationFrames)
            for side in AudioSide.allCases {
                let end =
                    manifest.segments.filter { $0.side == side }.map { $0.startFrame + $0.frames }.max() ?? 0
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
            return directory
        }
    }

    /// Called only on worker. Notifications leave that queue to allow safe client callbacks.
    private func fail(_ failure: RecorderFailure, manifest: inout RecordingManifest) {
        let message = failure.detail
        manifest.status = .failed
        manifest.failure = message
        manifest.failureCode = failure.media?.rawValue
        snapshotValue.manifest = manifest
        snapshotValue.error = message
        if let directory = snapshotValue.directory {
            do { try manifest.save(to: directory) } catch { snapshotValue.error = error.localizedDescription }
        }
        let notify = onFailure
        DispatchQueue.global(qos: .utility).async { notify(failure) }
    }
}
