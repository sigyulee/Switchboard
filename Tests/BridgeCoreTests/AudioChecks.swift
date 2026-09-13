import AVFAudio
import AudioRealtime
import BridgeCore
import Foundation
import RecorderKit

struct AudioChecks {
    func queueWrapAndOverflow() throws {
        guard let queue = sb_queue_create(4) else { throw CheckFailure(description: "queue allocation") }
        defer { sb_queue_destroy(queue) }
        let first: [Float] = [1, 2, 3, 4, 5, 6]
        try expect(first.withUnsafeBufferPointer { sb_queue_write(queue, $0.baseAddress, 3, 10) })
        try expect(!first.withUnsafeBufferPointer { sb_queue_write(queue, $0.baseAddress, 3, 20) })
        try expect(sb_queue_dropped(queue) == 3)
        var output = [Float](repeating: 0, count: 8)
        try expect(
            output.withUnsafeMutableBufferPointer { sb_queue_read(queue, $0.baseAddress, 2, nil) } == 2)
        try expect(Array(output.prefix(4)) == [1, 2, 3, 4])
        try expect(first.withUnsafeBufferPointer { sb_queue_write(queue, $0.baseAddress, 3, 20) })
        var time: UInt64 = 0
        try expect(
            output.withUnsafeMutableBufferPointer { sb_queue_read_packet(queue, $0.baseAddress, 4, &time) }
                == 1)
        try expect(time == 10 && output[0] == 5)
        try expect(
            output.withUnsafeMutableBufferPointer { sb_queue_read_packet(queue, $0.baseAddress, 4, &time) }
                == 3)
        try expect(time == 20 && Array(output.prefix(6)) == first)
        try expect(sb_queue_available(queue) == 0)
    }
    func timelineDoesNotReplayOldSlots() throws {
        var timeline = StereoTimeline(capacity: 4)
        timeline.insert([1, 1, 2, 2], at: 0)
        timeline.insert([3, 3], at: 4)
        try expect(timeline.read(at: 0, frames: 2) == [0, 0, 2, 2])
        try expect(timeline.read(at: 4, frames: 2) == [3, 3, 0, 0])
    }
    func leaseDoesNotRestoreOverExternalSelection() throws {
        var lease = InputLease(ownedUID: "caller", previousUID: "built-in")
        try expect(!lease.observed("caller"))
        try expect(lease.restoration(currentUID: "caller") == "built-in")
        try expect(lease.restoration(currentUID: "usb") == nil)
        try expect(lease.observed("usb"))
        try expect(lease.restoration(currentUID: "caller") == "usb")
    }
    func recordingMixAndRecovery() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "mih-check-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = ConversationRecorder()
        let directory = try recorder.start(root: root, owner: .manual)
        let a = [Float](repeating: 0.25, count: 48_000 * 2)
        let b = [Float](repeating: -0.1, count: 48_000 * 2)
        try expect(recorder.append(side: .caller, samples: a, frame: 0))
        try expect(recorder.append(side: .chrome, samples: b, frame: 48_000))
        _ = try recorder.finish(durationFrames: 96_000)
        let item = try RecordingRenderer.finalize(directory: directory)
        try expect(item.manifest.durationFrames == 96_000)
        try expect(item.manifest.segments.count == 2)
        try expect(
            item.manifest.gaps.contains { $0.side == .chrome && $0.startFrame == 0 && $0.frames == 48_000 })
        let mix = try AVAudioFile(forReading: item.mixURL)
        try expect(abs(mix.length - 96_000) < 2048)
        let source = root.appendingPathComponent("caller.wav")
        try RecordingRenderer.render(item: item, side: .caller, destination: source)
        let file = try AVAudioFile(forReading: source, commonFormat: .pcmFormatFloat32, interleaved: true)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 32) else {
            throw MediaFailure.invalidBuffer
        }
        try file.read(into: buffer, frameCount: 32)
        let decoded = try PCM.samples(buffer)
        try expect(decoded.allSatisfy { abs($0 - 0.25) < 0.00001 })
        let waveform = try Waveform.read(url: source, bins: 64)
        try expect(waveform.count == 64 && abs((waveform.max() ?? 0) - 0.25) < 0.00001)
        try expect(waveform.suffix(20).allSatisfy { $0 == 0 })
        var interrupted = item.manifest
        interrupted.status = .recording
        try interrupted.save(to: directory)
        let recovered = try RecordingLibrary.recover(
            RecordingItem(directory: directory, manifest: interrupted))
        try expect(recovered.manifest.status == .recoverable)
        try expect(recovered.manifest.segments.count == 2)
    }
}
