import AVFAudio
import BridgeCore
import CoreMedia
import Foundation
import RecorderKit
import Speech

/// A pull-through sequence: Speech controls consumption; there is no second unbounded buffer.
@available(macOS 26.0, *)
struct TranscriptAudioSequence: AsyncSequence, Sendable {
    typealias Element = AnalyzerInput
    let feeds: TranscriptFeeds
    let side: AudioSide
    let converter: TranscriptPCMConverter
    let gap: @Sendable (TranscriptGap) async -> Void

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(
            iterator: feeds.stream(for: side).makeAsyncIterator(), feeds: feeds,
            side: side, converter: converter, gap: gap)
    }

    struct AsyncIterator: AsyncIteratorProtocol {
        var iterator: AsyncStream<TranscriptAudioPacket>.Iterator
        let feeds: TranscriptFeeds
        let side: AudioSide
        let converter: TranscriptPCMConverter
        let gap: @Sendable (TranscriptGap) async -> Void

        mutating func next() async throws -> AnalyzerInput? {
            try Task.checkCancellation()
            let packet = await iterator.next()
            if packet != nil { feeds.didConsume(side: side) }
            for dropped in feeds.takeGaps(side: side) { await gap(dropped) }
            guard let packet else { return nil }
            return try await converter.convert(packet)
        }
    }
}

@available(macOS 26.0, *)
actor TranscriptPCMConverter {
    private let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter

    init(outputFormat: AVAudioFormat) throws {
        let input = try PCM.format()
        guard outputFormat.sampleRate.isFinite, (8000...192_000).contains(outputFormat.sampleRate),
            (1...2).contains(outputFormat.channelCount),
            let converter = AVAudioConverter(from: input, to: outputFormat)
        else { throw TranscriptFailure.unavailableFormat }
        self.outputFormat = outputFormat
        self.converter = converter
    }

    func convert(_ packet: TranscriptAudioPacket) throws -> AnalyzerInput {
        let input = try PCM.buffer(packet.samples)
        // Reset on every independently timestamped packet so resampler delay cannot move audio
        // across a source gap or a recorded/live boundary. Each packet is drained to end-of-stream.
        converter.reset()
        let capacity = AVAudioFrameCount(
            ceil(Double(input.frameLength) * outputFormat.sampleRate / 48_000) + 512)
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            throw TranscriptFailure.unavailableFormat
        }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            if supplied {
                state.pointee = .endOfStream
                return nil
            }
            supplied = true
            state.pointee = .haveData
            return input
        }
        if let error { throw error }
        guard status != .error, output.frameLength > 0 else { throw TranscriptFailure.invalidAudio }
        return AnalyzerInput(
            buffer: output, bufferStartTime: CMTime(value: packet.startFrame, timescale: 48_000))
    }
}
