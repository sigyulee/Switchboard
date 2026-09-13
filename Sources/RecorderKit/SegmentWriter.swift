import AVFAudio
import BridgeCore
import Foundation

final class SegmentWriter {
    static let segmentFrames: Int64 = 480_000
    let side: AudioSide
    let directory: URL
    private var file: AVAudioFile?
    private var start: Int64 = 0
    private var name = ""
    private(set) var cursor: Int64 = 0

    init(side: AudioSide, directory: URL) {
        self.side = side
        self.directory = directory
    }

    func append(_ samples: [Float], at frame: Int64, manifest: inout RecordingManifest) throws {
        var input = samples
        if frame < cursor {
            let overlap = min(input.count / 2, Int(cursor - frame))
            input.removeFirst(overlap * 2)
        } else if frame > cursor {
            manifest.gaps.append(
                AudioGap(
                    side: side, startFrame: cursor, frames: frame - cursor,
                    reason: "source unavailable or timestamp discontinuity"))
            try close(manifest: &manifest)
            cursor = frame
        }
        var consumed = 0
        while consumed < input.count {
            if file == nil {
                start = cursor
                name = "\(side.rawValue)-\(start).caf"
                file = try AVAudioFile(
                    forWriting: directory.appendingPathComponent(name), settings: PCM.format().settings,
                    commonFormat: .pcmFormatFloat32, interleaved: true)
            }
            let remaining = Self.segmentFrames - (cursor - start)
            let frames = min(Int(remaining), (input.count - consumed) / 2)
            guard frames > 0 else { throw MediaFailure.invalidBuffer }
            let part = Array(input[consumed..<consumed + frames * 2])
            try file?.write(from: PCM.buffer(part))
            cursor += Int64(frames)
            consumed += frames * 2
            manifest.durationFrames = max(manifest.durationFrames, cursor)
            if cursor - start == Self.segmentFrames {
                try close(manifest: &manifest)
                try manifest.save(to: directory)
            }
        }
    }

    func close(manifest: inout RecordingManifest) throws {
        guard file != nil else { return }
        file = nil
        let url = directory.appendingPathComponent(name)
        let handle = try FileHandle(forWritingTo: url)
        try handle.synchronize()
        try handle.close()
        manifest.segments.append(
            RecordingSegment(side: side, filename: name, startFrame: start, frames: cursor - start))
    }
}
