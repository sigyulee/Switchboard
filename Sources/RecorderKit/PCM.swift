import AVFAudio
import Foundation

public enum MediaFailure: String, Error, Equatable, LocalizedError, Sendable {
    case invalidFormat, invalidBuffer, noRecording, overrun, invalidPath
    case interrupted
    public var errorDescription: String? {
        switch self {
        case .invalidFormat: "The audio format is not supported."
        case .invalidBuffer: "The audio buffer is invalid."
        case .noRecording: "There is no recording to process."
        case .overrun: "Recording stopped because storage could not keep up. Original files are preserved."
        case .invalidPath: "Check the recording file path."
        case .interrupted: "Recording did not finish normally. Preserved originals can be recovered."
        }
    }
}

public enum PCM {
    public static let rate = 48_000.0
    public static func format(rate: Double = rate) throws -> AVAudioFormat {
        guard
            let result = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 2, interleaved: true)
        else { throw MediaFailure.invalidFormat }
        return result
    }
    public static func buffer(_ samples: [Float], rate: Double = rate) throws -> AVAudioPCMBuffer {
        let count = samples.count / 2
        guard samples.count.isMultiple(of: 2), count > 0, count <= Int(UInt32.max),
            let result = AVAudioPCMBuffer(pcmFormat: try format(rate: rate), frameCapacity: UInt32(count))
        else { throw MediaFailure.invalidBuffer }
        result.frameLength = UInt32(count)
        guard let pointer = result.mutableAudioBufferList.pointee.mBuffers.mData else {
            throw MediaFailure.invalidBuffer
        }
        samples.withUnsafeBytes { raw in
            if let base = raw.baseAddress { pointer.copyMemory(from: base, byteCount: raw.count) }
        }
        return result
    }
    public static func samples(_ buffer: AVAudioPCMBuffer) throws -> [Float] {
        guard buffer.format.commonFormat == .pcmFormatFloat32,
            buffer.format.isInterleaved, buffer.format.channelCount == 2
        else { throw MediaFailure.invalidFormat }
        guard buffer.frameLength > 0 else { return [] }
        let audio = buffer.audioBufferList.pointee
        let bytes = Int(buffer.frameLength) * 2 * MemoryLayout<Float>.size
        guard audio.mNumberBuffers == 1, Int(audio.mBuffers.mDataByteSize) >= bytes,
            let data = audio.mBuffers.mData
        else { throw MediaFailure.invalidBuffer }
        let samples = Array(
            UnsafeBufferPointer(
                start: data.assumingMemoryBound(to: Float.self), count: Int(buffer.frameLength) * 2))
        guard samples.allSatisfy(\.isFinite) else { throw MediaFailure.invalidBuffer }
        return samples
    }

    public static func requireRecordingFormat(_ format: AVAudioFormat) throws {
        guard format.sampleRate == rate, format.channelCount == 2 else { throw MediaFailure.invalidFormat }
    }
}

public final class SampleConverter {
    private let sourceRate: Double
    private let targetRate: Double
    private let converter: AVAudioConverter?
    public init(from: Double, to: Double = PCM.rate) throws {
        guard from.isFinite, to.isFinite, from > 0, to > 0 else { throw MediaFailure.invalidFormat }
        sourceRate = from
        targetRate = to
        if from == to {
            converter = nil
        } else {
            guard
                let result = AVAudioConverter(from: try PCM.format(rate: from), to: try PCM.format(rate: to))
            else { throw MediaFailure.invalidFormat }
            result.sampleRateConverterQuality = AVAudioQuality.high.rawValue
            converter = result
        }
    }
    public func convert(_ samples: [Float]) throws -> [Float] {
        guard samples.count.isMultiple(of: 2), samples.allSatisfy(\.isFinite) else {
            throw MediaFailure.invalidBuffer
        }
        guard !samples.isEmpty else { return [] }
        guard let converter else { return samples }
        let input = try PCM.buffer(samples, rate: sourceRate)
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * targetRate / sourceRate) + 128)
        guard
            let output = AVAudioPCMBuffer(
                pcmFormat: try PCM.format(rate: targetRate), frameCapacity: capacity)
        else { throw MediaFailure.invalidBuffer }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            if supplied {
                state.pointee = .noDataNow
                return nil
            }
            supplied = true
            state.pointee = .haveData
            return input
        }
        if let error { throw error }
        if status == .error { throw MediaFailure.invalidBuffer }
        return try PCM.samples(output)
    }
}
