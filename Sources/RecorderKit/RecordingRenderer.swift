import AVFAudio
import BridgeCore
import Foundation

public enum RecordingRenderer {
    public static func render(
        item: RecordingItem, side: AudioSide? = nil, destination: URL,
        progress: @Sendable (Double) -> Void = { _ in }
    ) throws {
        try item.manifest.validate()
        guard item.manifest.durationFrames > 0 else { throw MediaFailure.noRecording }
        let caller = SourceReader(item: item, side: .caller)
        let chrome = SourceReader(item: item, side: .chrome)
        let settings: [String: Any]
        if destination.pathExtension.lowercased() == "m4a" {
            settings = [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: PCM.rate,
                AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192_000,
            ]
        } else {
            settings = try PCM.format().settings
        }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(
            ".\(UUID().uuidString).\(destination.pathExtension)")
        var output: AVAudioFile? = try AVAudioFile(
            forWriting: temporary, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: true)
        do {
            var position: Int64 = 0
            while position < item.manifest.durationFrames {
                if Task<Never, Never>.isCancelled { throw CancellationError() }
                let count = Int(min(4096, item.manifest.durationFrames - position))
                let a = side == .chrome ? [] : try caller.read(at: position, frames: count)
                let b = side == .caller ? [] : try chrome.read(at: position, frames: count)
                let samples: [Float]
                if side == .caller {
                    samples = a
                } else if side == .chrome {
                    samples = b
                } else {
                    samples = zip(a, b).map { min(1, max(-1, ($0 + $1) * 0.5)) }
                }
                try output?.write(from: PCM.buffer(samples))
                position += Int64(count)
                progress(Double(position) / Double(item.manifest.durationFrames))
            }
            output = nil
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: destination)
            }
        } catch {
            output = nil
            if FileManager.default.fileExists(atPath: temporary.path) {
                try? FileManager.default.removeItem(at: temporary)
            }
            throw error
        }
    }

    public static func finalize(directory: URL) throws -> RecordingItem {
        var manifest = try RecordingManifest.load(from: directory)
        let original = RecordingItem(directory: directory, manifest: manifest)
        do {
            try render(item: original, destination: original.mixURL)
            manifest = try RecordingManifest.load(from: directory)
            manifest.status = manifest.failure == nil ? .complete : .recoverable
            try manifest.save(to: directory)
        } catch {
            manifest.status = .recoverable
            manifest.failure = error.localizedDescription
            manifest.failureCode = (error as? MediaFailure)?.rawValue
            try manifest.save(to: directory)
            throw error
        }
        return RecordingItem(directory: directory, manifest: manifest)
    }
}
