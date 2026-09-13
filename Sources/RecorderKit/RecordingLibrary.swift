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
        return children.filter { $0.pathExtension == "mihrecording" }.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                values.isDirectory == true, values.isSymbolicLink != true,
                let manifest = try? RecordingManifest.load(from: url)
            else { return nil }
            return RecordingItem(directory: url, manifest: manifest)
        }.sorted { $0.manifest.createdAt > $1.manifest.createdAt }
    }

    public static func recover(_ item: RecordingItem) throws -> RecordingItem {
        var manifest = item.manifest
        try manifest.validate()
        guard manifest.status != .complete else { return item }
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
        var manifest = item.manifest
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        manifest.title = value
        try manifest.save(to: item.directory)
    }
}

final class SourceReader {
    private let directory: URL
    private let segments: [RecordingSegment]
    private var currentName: String?
    private var file: AVAudioFile?
    init(item: RecordingItem, side: AudioSide) {
        directory = item.directory
        segments = item.manifest.segments.filter { $0.side == side }.sorted { $0.startFrame < $1.startFrame }
    }
    func read(at start: Int64, frames: Int) throws -> [Float] {
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
