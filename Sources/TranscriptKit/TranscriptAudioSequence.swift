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
        private var pending: IndexingIterator<[AnalyzerInput]> = [].makeIterator()
        private var finished = false

        init(
            iterator: AsyncStream<TranscriptAudioPacket>.Iterator, feeds: TranscriptFeeds,
            side: AudioSide, converter: TranscriptPCMConverter,
            gap: @escaping @Sendable (TranscriptGap) async -> Void
        ) {
            self.iterator = iterator
            self.feeds = feeds
            self.side = side
            self.converter = converter
            self.gap = gap
        }

        mutating func next() async throws -> AnalyzerInput? {
            while true {
                try Task.checkCancellation()
                if let input = pending.next() { return input }
                guard !finished else { return nil }
                let packet = await iterator.next()
                if packet != nil { feeds.didConsume(side: side) }
                try Task.checkCancellation()
                for dropped in feeds.takeGaps(side: side) {
                    await gap(dropped)
                    try Task.checkCancellation()
                }
                if let packet {
                    pending = try await converter.convert(packet).makeIterator()
                } else {
                    pending = try await converter.finish().makeIterator()
                    finished = true
                }
            }
        }
    }
}

@available(macOS 26.0, *)
actor TranscriptPCMConverter {
    private let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter
    private let outputRate: Int64
    private var runStart: Int64?
    private var sourceEnd: Int64 = 0
    private var emittedFrames: Int64 = 0
    private var finished = false

    init(outputFormat: AVAudioFormat) throws {
        let input = try PCM.format()
        guard outputFormat.sampleRate.isFinite, (8000...192_000).contains(outputFormat.sampleRate),
            outputFormat.sampleRate.rounded(.down) == outputFormat.sampleRate,
            (1...2).contains(outputFormat.channelCount),
            let converter = AVAudioConverter(from: input, to: outputFormat)
        else { throw TranscriptFailure.unavailableFormat }
        self.outputFormat = outputFormat
        self.converter = converter
        outputRate = Int64(outputFormat.sampleRate)
    }

    /// Each call produces at most four buffers: a bounded old-run drain and the
    /// new packet's output. Normal priming may produce no output yet.
    func convert(_ packet: TranscriptAudioPacket) throws -> [AnalyzerInput] {
        try Task.checkCancellation()
        guard !finished, runStart == nil || packet.startFrame >= sourceEnd else {
            throw TranscriptFailure.invalidAudio
        }
        var result: [AnalyzerInput] = []
        if runStart != nil, packet.startFrame != sourceEnd {
            result = try drain()
            converter.reset()
            runStart = nil
        }
        if runStart == nil {
            runStart = packet.startFrame
            emittedFrames = 0
        }
        sourceEnd = packet.endFrame
        let input = try PCM.buffer(packet.samples)
        let output = try outputBuffer()
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
        guard supplied, status == .inputRanDry,
            Int64(output.frameLength) <= remainingFrames
        else { throw TranscriptFailure.invalidAudio }
        if let input = try emit(output) { result.append(input) }
        return result
    }

    func finish() throws -> [AnalyzerInput] {
        try Task.checkCancellation()
        guard !finished else { return [] }
        finished = true
        return try drain()
    }

    /// Count complete output samples over the entire contiguous source interval.
    /// The validated 30-day source limit and maximum rate keep this product in Int64.
    private var remainingFrames: Int64 {
        guard let runStart else { return 0 }
        return (sourceEnd - runStart) * outputRate / 48_000 - emittedFrames
    }

    private func outputBuffer() throws -> AVAudioPCMBuffer {
        let remaining = remainingFrames
        // Packets hold at most one second. Bound converter lookahead/backlog to
        // another second, and reserve one fractional sample so all input is
        // consumed before .noDataNow rather than retained in an input callback.
        guard (0...(2 * outputRate)).contains(remaining),
            let output = AVAudioPCMBuffer(
                pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(remaining + 1))
        else { throw TranscriptFailure.invalidAudio }
        return output
    }

    private func drain() throws -> [AnalyzerInput] {
        guard runStart != nil else { return [] }
        var result: [AnalyzerInput] = []
        // PCM drain can return a final .haveData before its .endOfStream. Keep
        // both the work and retained output bounded if the converter misbehaves.
        for _ in 0..<3 {
            try Task.checkCancellation()
            let output = try outputBuffer()
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, state in
                state.pointee = .endOfStream
                return nil
            }
            if let error { throw error }
            guard status != .error, status != .inputRanDry else { throw TranscriptFailure.invalidAudio }
            // Only the final fractional sample is discarded, once per actual
            // gap/end, so a buffer's duration never reaches beyond its source.
            guard Int64(output.frameLength) <= remainingFrames + 1 else {
                throw TranscriptFailure.invalidAudio
            }
            output.frameLength = AVAudioFrameCount(min(Int64(output.frameLength), remainingFrames))
            if let input = try emit(output) { result.append(input) }
            if status == .endOfStream {
                guard remainingFrames == 0 else { throw TranscriptFailure.invalidAudio }
                return result
            }
        }
        throw TranscriptFailure.invalidAudio
    }

    private func emit(_ buffer: AVAudioPCMBuffer) throws -> AnalyzerInput? {
        guard buffer.frameLength > 0 else { return nil }
        guard let runStart else { throw TranscriptFailure.invalidAudio }
        let start = CMTimeAdd(
            CMTime(value: runStart, timescale: 48_000),
            CMTime(value: emittedFrames, timescale: CMTimeScale(outputRate)))
        emittedFrames += Int64(buffer.frameLength)
        return AnalyzerInput(buffer: buffer, bufferStartTime: start)
    }
}
