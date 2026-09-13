import AVFAudio
import Foundation

public enum Waveform {
    public static func read(url: URL, bins: Int = 240) throws -> [Float] {
        guard bins > 0 && bins <= 4096 else { throw MediaFailure.invalidBuffer }
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: true)
        guard file.length > 0,
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096)
        else { return [] }
        var values = [Float](repeating: 0, count: bins)
        let channels = Int(file.processingFormat.channelCount)
        var position: Int64 = 0
        while position < file.length {
            if Task<Never, Never>.isCancelled { throw CancellationError() }
            try file.read(into: buffer, frameCount: UInt32(min(4096, file.length - position)))
            guard buffer.frameLength > 0, let raw = buffer.audioBufferList.pointee.mBuffers.mData else {
                break
            }
            let samples = raw.assumingMemoryBound(to: Float.self)
            for frame in 0..<Int(buffer.frameLength) {
                let bin = min(
                    bins - 1, Int(Double(position + Int64(frame)) / Double(file.length) * Double(bins)))
                for channel in 0..<channels {
                    values[bin] = max(values[bin], abs(samples[frame * channels + channel]))
                }
            }
            position += Int64(buffer.frameLength)
        }
        return values
    }
}
