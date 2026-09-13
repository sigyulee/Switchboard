import AVFAudio
import BridgeCore
import Foundation
import RecorderKit

struct RecordingValidationChecks {
    func nonFiniteAudioIsRejected() throws {
        let converter = try SampleConverter(from: 48_000)
        try expectThrows { _ = try converter.convert([.nan, 0]) }
        try expectThrows { _ = try converter.convert([0, .infinity]) }
        let buffer = try PCM.buffer([.nan, 0])
        try expectThrows { _ = try PCM.samples(buffer) }
    }

    func rejectedAudioCannotBecomeACompleteRecording() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = ConversationRecorder(maximumPendingBytes: 16)
        let directory = try recorder.start(root: root, owner: .manual)
        try expect(!recorder.append(side: .caller, samples: [Float](repeating: 0.1, count: 16), frame: 0))
        _ = try recorder.finish(durationFrames: 8)
        let item = try RecordingRenderer.finalize(directory: directory)
        try expect(item.manifest.status == .recoverable)
        try expect(item.manifest.failure != nil)
        try expect(item.manifest.gaps.contains { $0.side == .caller && $0.frames == 8 })
        try expect(!recorder.append(side: .caller, samples: [0, 0], frame: 8))
    }

    func malformedManifestsAreRejected() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var manifest = RecordingManifest(title: "Fixture", owner: .manual)
        manifest.durationFrames = 48_000
        manifest.sampleRate = 0
        try JSONEncoder().encode(manifest).write(to: directory.appendingPathComponent("manifest.json"))
        try expectThrows { _ = try RecordingManifest.load(from: directory) }
        manifest.sampleRate = 48_000
        manifest.segments = [
            RecordingSegment(side: .caller, filename: "caller-0.caf", startFrame: .max, frames: 64)
        ]
        try JSONEncoder().encode(manifest).write(to: directory.appendingPathComponent("manifest.json"))
        try expectThrows { _ = try RecordingManifest.load(from: directory) }
        manifest.segments = [
            RecordingSegment(side: .caller, filename: "../private.caf", startFrame: 0, frames: 64)
        ]
        try JSONEncoder().encode(manifest).write(to: directory.appendingPathComponent("manifest.json"))
        try expectThrows { _ = try RecordingManifest.load(from: directory) }
    }

    func monoBuffersAreRejected() throws {
        guard
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: true),
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8)
        else {
            throw CheckFailure(description: "mono fixture allocation")
        }
        buffer.frameLength = 1
        try expectThrows { _ = try PCM.samples(buffer) }
    }

    func recoveryRejectsNonCanonicalAudio() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 1, interleaved: true)!
        var file: AVAudioFile? = try AVAudioFile(
            forWriting: directory.appendingPathComponent("caller-0.caf"), settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: file!.processingFormat, frameCapacity: 16)!
        buffer.frameLength = 16
        try file!.write(from: buffer)
        file = nil
        let manifest = RecordingManifest(title: "Fixture", owner: .manual)
        try manifest.save(to: directory)
        try expectThrows {
            _ = try RecordingLibrary.recover(RecordingItem(directory: directory, manifest: manifest))
        }
    }
}
