import AVFAudio
import BridgeCore
import CoreMedia
import Darwin
import Foundation
import Speech

struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw CheckFailure(description: message) }
}

@main struct PCMChecks {
    static func main() async {
        do {
            try await shortPacketsDoNotOverlap()
            try await packetizationPreservesWaveform()
            try await fractionalDurationAndLargeStartStayExact()
            try await gapsKeepTheirOwnTails()
            try await tinyPacketsPrimeAndDrain()
            try await cancellationStopsDelivery()
            try await cancellationDiscardsPendingOutput()
            try await duplicateSourceAudioIsRejected()
            print("Transcription PCM checks passed.")
        } catch {
            FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
            exit(1)
        }
    }

    static func format() throws -> AVAudioFormat {
        guard
            let format = AVAudioFormat(
                commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false)
        else { throw CheckFailure(description: "Missing speech PCM format") }
        return format
    }

    static func signal(frames: Int, offset: Int = 0) -> [Float] {
        (0..<frames).flatMap { frame -> [Float] in
            let value = Float(sin(Double(frame + offset) * 2 * .pi * 440 / 48_000)) * 0.25
            return [value, value]
        }
    }

    static func collect(_ packets: [TranscriptAudioPacket]) async throws -> [AnalyzerInput] {
        let feeds = TranscriptFeeds(maximumBufferedPackets: 256, maximumPacketFrames: 48_000)
        for packet in packets {
            try require(
                feeds.append(side: .caller, samples: packet.samples, startFrame: packet.startFrame),
                "Test feed did not accept packet")
        }
        feeds.finish()
        let sequence = TranscriptAudioSequence(
            feeds: feeds, side: .caller, converter: try TranscriptPCMConverter(outputFormat: format()),
            gap: { _ in })
        var result: [AnalyzerInput] = []
        for try await input in sequence { result.append(input) }
        return result
    }

    static func shortPacketsDoNotOverlap() async throws {
        let packets = try (0..<6).map { index in
            try TranscriptAudioPacket(
                samples: signal(frames: 512, offset: index * 512),
                startFrame: Int64(index * 512))
        }
        let output = try await collect(packets)
        try timeline(output, start: 0, frames: 3072)
        try require(
            output.reduce(0) { $0 + Int($1.buffer.frameLength) } == 1024,
            "3072 input frames must yield exactly 1024 output frames")
    }

    static func timeline(_ output: [AnalyzerInput], start sourceStart: Int64, frames: Int64) throws {
        var previousEnd = CMTime(value: sourceStart, timescale: 48_000)
        for (index, input) in output.enumerated() {
            guard let start = input.bufferStartTime else {
                throw CheckFailure(description: "Output has no timestamp")
            }
            try require(
                CMTimeCompare(start, previousEnd) == 0,
                "Output \(index) must be contiguous: \(start) != \(previousEnd)")
            try require(input.buffer.frameLength > 0, "Empty analyzer input")
            previousEnd = CMTimeAdd(start, CMTime(value: Int64(input.buffer.frameLength), timescale: 16_000))
        }
        let sourceEnd = CMTime(value: sourceStart + frames, timescale: 48_000)
        let remainder = CMTimeSubtract(sourceEnd, previousEnd)
        try require(
            CMTimeCompare(remainder, .zero) >= 0,
            "Output extends past the source interval")
        try require(
            CMTimeCompare(remainder, CMTime(value: 1, timescale: 16_000)) < 0,
            "Conversion lost at least one complete output frame")
    }

    static func samples(_ output: [AnalyzerInput]) throws -> [Int16] {
        try output.flatMap { input in
            let buffer = input.buffer
            guard let data = buffer.int16ChannelData else {
                throw CheckFailure(description: "Expected supported mono Int16 speech PCM")
            }
            return Array(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
        }
    }

    static func packetizationPreservesWaveform() async throws {
        // Resetting the resampler for every packet corrupts the waveform even if
        // someone later hides its duration drift by adjusting timestamps.
        let source = signal(frames: 48_000)
        let whole = try await collect([
            TranscriptAudioPacket(samples: source, startFrame: 0, maximumFrames: 48_000)
        ])
        var packets: [TranscriptAudioPacket] = []
        var cursor = 0
        while cursor < 48_000 {
            let end = min(48_000, cursor + 512)
            packets.append(
                try TranscriptAudioPacket(
                    samples: Array(source[(cursor * 2)..<(end * 2)]),
                    startFrame: Int64(cursor)))
            cursor = end
        }
        let divided = try await collect(packets)
        try timeline(divided, start: 0, frames: 48_000)
        let expected = try samples(whole)
        let actual = try samples(divided)
        try require(
            actual.count == 16_000 && actual.count == expected.count,
            "Packet boundaries change total sample count")
        let maximumDifference = zip(actual, expected).map { abs(Int($0) - Int($1)) }.max() ?? 0
        try require(maximumDifference <= 1, "Packet boundaries change PCM by \(maximumDifference) LSB")
        // An independent sine checks gain/phase rather than only comparing two
        // packetizations of the same converter. Ignore only the stream edges.
        let squaredError = (32..<(actual.count - 32)).reduce(0.0) { sum, index in
            let ideal = sin(Double(index) * 2 * .pi * 440 / 16_000) * 0.25
            let error = Double(actual[index]) / 32768 - ideal
            return sum + error * error
        }
        try require(
            sqrt(squaredError / Double(actual.count - 64)) < 0.0002,
            "Converted sine has gain, phase, or continuity damage")
    }

    static func fractionalDurationAndLargeStartStayExact() async throws {
        let start = TranscriptLimits.maximumFrame - 102_401
        var packets = try (0..<200).map { index in
            try TranscriptAudioPacket(
                samples: signal(frames: 512, offset: index * 512),
                startFrame: start + Int64(index * 512))
        }
        packets.append(try TranscriptAudioPacket(samples: [0, 0], startFrame: start + 102_400))
        let output = try await collect(packets)
        try timeline(output, start: start, frames: 102_401)
        try require(
            try samples(output).count == 34_133,
            "Fractional packets accumulate sample-count drift")
    }

    static func gapsKeepTheirOwnTails() async throws {
        for gap in [1, 48_000] {
            let secondStart = Int64(512 + gap)
            let first = try TranscriptAudioPacket(samples: signal(frames: 512), startFrame: 0)
            let second = try TranscriptAudioPacket(
                samples: Array(repeating: 0, count: 1024),
                startFrame: secondStart)
            let output = try await collect([first, second])
            let boundary = CMTime(value: secondStart, timescale: 48_000)
            let before = output.filter { CMTimeCompare($0.bufferStartTime!, boundary) < 0 }
            let after = output.filter { CMTimeCompare($0.bufferStartTime!, boundary) >= 0 }
            try timeline(before, start: 0, frames: 512)
            try timeline(after, start: secondStart, frames: 512)
            let alone = try await collect([first])
            try require(try samples(before) == samples(alone), "Source gap lost or moved the preceding tail")
            try require(
                try samples(after).allSatisfy { $0 == 0 }, "Old resampler tail crossed the source gap")
        }
    }

    static func tinyPacketsPrimeAndDrain() async throws {
        let packets = try (0..<6).map { index in
            try TranscriptAudioPacket(samples: [0.25, 0.25], startFrame: Int64(index))
        }
        let output = try await collect(packets)
        try timeline(output, start: 0, frames: 6)
        try require(try samples(output).count == 2, "Priming or feed finish lost short audio")
        let subframe = try await collect([TranscriptAudioPacket(samples: [0, 0], startFrame: 0)])
        try require(subframe.isEmpty, "A fractional final sample extends beyond the source interval")
        try require(try await collect([]).isEmpty, "An empty feed created output")
    }

    static func cancellationStopsDelivery() async throws {
        let feeds = TranscriptFeeds(maximumBufferedPackets: 1)
        try require(
            feeds.append(side: .caller, samples: signal(frames: 512), startFrame: 0),
            "Cancellation fixture admission failed")
        try require(
            !feeds.append(side: .caller, samples: [0, 0], startFrame: 512),
            "Cancellation fixture must report a queue gap")
        let (entered, notify) = AsyncStream<Void>.makeStream()
        let (blocked, release) = AsyncStream<Void>.makeStream()
        let sequence = TranscriptAudioSequence(
            feeds: feeds, side: .caller, converter: try TranscriptPCMConverter(outputFormat: format()),
            gap: { _ in
                notify.yield(())
                for await _ in blocked { break }
            })
        let task = Task {
            var iterator = sequence.makeAsyncIterator()
            do {
                _ = try await iterator.next()
                return false
            } catch is CancellationError {
                return true
            }
        }
        for await _ in entered { break }
        task.cancel()
        release.finish()
        notify.finish()
        try require(try await task.value, "Cancellation during a gap callback still delivered analyzer input")
        feeds.finish()
    }

    static func duplicateSourceAudioIsRejected() async throws {
        do {
            _ = try await collect([
                TranscriptAudioPacket(samples: signal(frames: 512), startFrame: 0),
                TranscriptAudioPacket(samples: signal(frames: 512), startFrame: 256),
            ])
            throw CheckFailure(description: "Overlapping source packets duplicated analyzed audio")
        } catch TranscriptFailure.invalidAudio {
            // A backward source timestamp cannot be repaired by resampling.
        }
    }

    static func cancellationDiscardsPendingOutput() async throws {
        let feeds = TranscriptFeeds()
        for start: Int64 in [0, 48_000] {
            try require(
                feeds.append(side: .caller, samples: signal(frames: 512), startFrame: start),
                "Pending-output cancellation fixture admission failed")
        }
        feeds.finish()
        let sequence = TranscriptAudioSequence(
            feeds: feeds, side: .caller, converter: try TranscriptPCMConverter(outputFormat: format()),
            gap: { _ in })
        let task = Task {
            var iterator = sequence.makeAsyncIterator()
            // First: initial output. Second: the first run's drained tail.
            // The second run's first buffer remains in the iterator's bounded queue.
            try require(try await iterator.next() != nil, "Missing initial output")
            try require(try await iterator.next() != nil, "Missing source-gap tail")
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await iterator.next()
                return false
            } catch is CancellationError {
                return true
            }
        }
        try require(try await task.value, "Cancellation delivered already-converted pending output")
    }
}
