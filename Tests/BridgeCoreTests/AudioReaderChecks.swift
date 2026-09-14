import AVFAudio
import BridgeCore
import Foundation
import RecorderKit

struct AudioReaderChecks {
    func partialFileReadsPreserveNonzeroTail() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = sentinel(frames: 50_594)
        for format: AVAudioCommonFormat in [.pcmFormatFloat32, .pcmFormatInt16] {
            let filename = "source-\(format.rawValue).caf"
            try write(source, to: root.appendingPathComponent(filename), format: format)
            let item = try item(
                root: root,
                segments: [
                    RecordingSegment(side: .caller, filename: filename, startFrame: 0, frames: 50_594)
                ])
            let reader = try RecordingAudioReader(item: item, side: .caller)
            let actual = try reader.read(at: 0, frames: 50_594)
            try expect(actual == source)
            // Seeks and short range reads must also stop at the requested frame,
            // rather than consuming or replaying another part of the segment.
            try expect(reader.read(at: 49_901, frames: 693) == Array(source[(49_901 * 2)...]))
            try expect(reader.read(at: 17, frames: 2_047) == Array(source[34..<(2_064 * 2)]))
        }
    }

    func partialReadsPreserveDeclaredTimelineGaps() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = sentinel(frames: 50_594)
        let second = first.map { -$0 }
        try write(first, to: root.appendingPathComponent("first.caf"))
        try write(second, to: root.appendingPathComponent("second.caf"))
        let item = try item(
            root: root,
            segments: [
                RecordingSegment(side: .caller, filename: "first.caf", startFrame: 37, frames: 50_594),
                RecordingSegment(side: .caller, filename: "second.caf", startFrame: 52_679, frames: 50_594),
            ], gaps: [AudioGap(side: .caller, startFrame: 50_631, frames: 2_048, reason: "Paused")])
        let reader = try RecordingAudioReader(item: item, side: .caller)
        let expected =
            Array(repeating: Float.zero, count: 74) + first
            + Array(repeating: Float.zero, count: 4_096) + second
            + Array(repeating: Float.zero, count: 38)
        try expect(reader.read(at: 0, frames: 103_292) == expected)
        let other = try RecordingAudioReader(item: item, side: .agent)
        try expect(other.read(at: 0, frames: 103_292).allSatisfy { $0 == 0 })
    }

    func prematurelyTruncatedSegmentIsRejected() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("source.caf")
        try write(sentinel(frames: 50_594), to: fileURL)
        let item = try item(
            root: root,
            segments: [
                RecordingSegment(side: .caller, filename: "source.caf", startFrame: 0, frames: 50_594)
            ])
        let reader = try RecordingAudioReader(item: item, side: .caller)
        // Open and cache the segment's original length, then truncate real PCM
        // underneath it. A declared segment's missing bytes are not a session gap.
        _ = try reader.read(at: 0, frames: 1)
        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.truncate(atOffset: 0)
        try handle.close()
        try expectThrows { _ = try reader.read(at: 49_901, frames: 693) }
    }

    func cancelledReadDoesNotReturnAudioOrInventSilence() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = sentinel(frames: 50_594)
        try write(source, to: root.appendingPathComponent("source.caf"))
        let item = try item(
            root: root,
            segments: [
                RecordingSegment(side: .caller, filename: "source.caf", startFrame: 0, frames: 50_594)
            ])
        for side in AudioSide.allCases {
            let task = Task {
                let reader = try RecordingAudioReader(item: item, side: side)
                withUnsafeCurrentTask { $0?.cancel() }
                do {
                    _ = try reader.read(at: 0, frames: 50_594)
                    return false
                } catch is CancellationError {
                    return true
                }
            }
            let cancelled = try await task.value
            try expect(cancelled)
        }
    }

    private func sentinel(frames: Int) -> [Float] {
        (0..<frames).flatMap { frame -> [Float] in
            if frame >= frames - 450 { return [0.75, -0.5] }
            return [Float((frame % 16) + 1) / 64, -Float((frame % 8) + 1) / 32]
        }
    }

    private func write(
        _ samples: [Float], to url: URL, format: AVAudioCommonFormat = .pcmFormatFloat32
    ) throws {
        guard
            let format = AVAudioFormat(
                commonFormat: format, sampleRate: 48_000, channels: 2, interleaved: true)
        else { throw MediaFailure.invalidFormat }
        let file = try AVAudioFile(
            forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: true)
        try file.write(from: PCM.buffer(samples))
    }

    private func item(
        root: URL, segments: [RecordingSegment], gaps: [AudioGap] = []
    ) throws -> RecordingItem {
        var manifest = RecordingManifest(title: "Audio reader fixture", owner: .manual)
        manifest.durationFrames = segments.map { $0.startFrame + $0.frames }.max() ?? 0
        manifest.segments = segments
        manifest.gaps = gaps
        try manifest.validate()
        return RecordingItem(directory: root, manifest: manifest)
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "switchboard-audio-reader-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }
}
