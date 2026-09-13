import AVFAudio
import BridgeCore
import Foundation

public struct RecordingItem: Equatable, Identifiable, Sendable {
    public let directory: URL
    public var manifest: RecordingManifest
    public var id: UUID { manifest.id }
    public var mixURL: URL { directory.appendingPathComponent("Conversation.m4a") }
    public init(directory: URL, manifest: RecordingManifest) {
        self.directory = directory
        self.manifest = manifest
    }
}

public enum RecordingLibrary {
    public static func items(in root: URL) throws -> [RecordingItem] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let children = try FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        return children.compactMap { try? item(at: $0) }.sorted {
            $0.manifest.createdAt > $1.manifest.createdAt
        }
    }

    public static func item(at directory: URL) throws -> RecordingItem {
        guard directory.isFileURL,
            ["mihrecording", "switchboard"].contains(directory.pathExtension.lowercased())
        else {
            throw MediaFailure.invalidPath
        }
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw MediaFailure.invalidPath
        }
        let manifest = try RecordingManifest.load(from: directory)
        if directory.pathExtension.lowercased() == SessionManifest.packageExtension
            || FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(SessionManifest.filename).path)
        {
            let session = try SessionStore.metadata(in: directory)
            guard session.id == manifest.id, session.createdAt == manifest.createdAt else {
                throw SessionStoreError.identityMismatch
            }
        }
        return RecordingItem(directory: directory, manifest: manifest)
    }

    /// Reconcile explicitly opened files without registering or scanning their parent folders.
    public static func refreshed(_ previous: [RecordingItem]) -> [RecordingItem] {
        previous.compactMap { old in
            guard let current = try? item(at: old.directory), current.id == old.id else { return nil }
            return current
        }
    }

    public static func recover(_ item: RecordingItem) throws -> RecordingItem {
        var manifest = try RecordingManifest.load(from: item.directory)
        guard manifest.status != .complete else {
            return RecordingItem(directory: item.directory, manifest: manifest)
        }
        let children = try FileManager.default.contentsOfDirectory(
            at: item.directory, includingPropertiesForKeys: [.isSymbolicLinkKey])
        for url in children where url.pathExtension == "caf" {
            guard !manifest.segments.contains(where: { $0.filename == url.lastPathComponent }),
                (try url.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true
            else { continue }
            let components = url.deletingPathExtension().lastPathComponent.split(separator: "-")
            guard components.count == 2, let side = AudioSide(rawValue: String(components[0])),
                let start = Int64(components[1]), start >= 0,
                let file = try? AVAudioFile(forReading: url), file.length > 0
            else { continue }
            try PCM.requireRecordingFormat(file.processingFormat)
            let (end, overflow) = start.addingReportingOverflow(file.length)
            guard !overflow else { throw RecordingManifestError.invalidTimeline }
            manifest.segments.append(
                RecordingSegment(
                    side: side, filename: url.lastPathComponent, startFrame: start, frames: file.length))
            manifest.durationFrames = max(manifest.durationFrames, end)
        }
        manifest.status = .recoverable
        if manifest.failure == nil {
            manifest.failure = MediaFailure.interrupted.localizedDescription
            manifest.failureCode = MediaFailure.interrupted.rawValue
        }
        try manifest.save(to: item.directory)
        return RecordingItem(directory: item.directory, manifest: manifest)
    }

    public static func rename(_ item: RecordingItem, title: String) throws {
        var manifest = try RecordingManifest.load(from: item.directory)
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        manifest.title = value
        try manifest.save(to: item.directory)
    }
}

public final class RecordingAudioReader {
    private let directory: URL
    private let segments: [RecordingSegment]
    private var currentName: String?
    private var file: AVAudioFile?
    public init(item: RecordingItem, side: AudioSide) throws {
        try item.manifest.validate()
        directory = item.directory
        segments = item.manifest.segments.filter { $0.side == side }.sorted { $0.startFrame < $1.startFrame }
    }
    public func read(at start: Int64, frames: Int) throws -> [Float] {
        let (_, overflow) = start.addingReportingOverflow(Int64(frames))
        guard start >= 0, frames > 0, frames <= 480_000, !overflow else { throw MediaFailure.invalidBuffer }
        var result = [Float](repeating: 0, count: frames * 2)
        for segment in segments
        where segment.startFrame < start + Int64(frames) && segment.startFrame + segment.frames > start {
            guard segment.filename == URL(fileURLWithPath: segment.filename).lastPathComponent else {
                throw MediaFailure.invalidPath
            }
            if currentName != segment.filename {
                let url = directory.appendingPathComponent(segment.filename)
                guard (try url.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else {
                    throw MediaFailure.invalidPath
                }
                file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: true)
                guard let file, file.length >= segment.frames else { throw MediaFailure.invalidBuffer }
                try PCM.requireRecordingFormat(file.processingFormat)
                currentName = segment.filename
            }
            guard let file else { throw MediaFailure.invalidBuffer }
            let begin = max(start, segment.startFrame)
            let end = min(start + Int64(frames), segment.startFrame + segment.frames)
            let count = Int(end - begin)
            file.framePosition = begin - segment.startFrame
            guard
                let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: UInt32(count))
            else { throw MediaFailure.invalidBuffer }
            try file.read(into: buffer, frameCount: UInt32(count))
            let samples = try PCM.samples(buffer)
            let offset = Int(begin - start) * 2
            for i in samples.indices where offset + i < result.count { result[offset + i] = samples[i] }
        }
        return result
    }
}
