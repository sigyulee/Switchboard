import Foundation

public struct TimedAudio: Sendable {
    public let side: AudioSide
    public let samples: [Float]
    public let startFrame: Int64
    public var endFrame: Int64 { startFrame + Int64(samples.count / 2) }

    public init(side: AudioSide, samples: [Float], startFrame: Int64) throws {
        guard startFrame >= 0, !samples.isEmpty, samples.count.isMultiple(of: 2),
            samples.allSatisfy(\.isFinite),
            !startFrame.addingReportingOverflow(Int64(samples.count / 2)).overflow
        else {
            throw RecordingManifestError.invalidTimeline
        }
        self.side = side
        self.samples = samples
        self.startFrame = startFrame
    }

    public func after(_ frame: Int64) -> Self? {
        guard frame >= 0, endFrame > frame else { return nil }
        let skip = Int(max(0, frame - startFrame))
        return try? Self(
            side: side, samples: Array(samples.dropFirst(skip * 2)), startFrame: max(frame, startFrame))
    }
}

/// A short handoff buffer while a transcript worker catches up with recorded audio.
/// It owns no files; recording-disabled audio cannot spill to disk.
public struct AudioHistory: Sendable {
    public let id = UUID()
    public private(set) var sequence: UInt64 = 0
    private let beginFrame: Int64
    private let maximumSamples: Int
    private let maximumLossIntervals: Int
    private var samples = 0
    private var packets: [TimedAudio] = []
    private var evicted: [AudioSide: [SessionInterval]] = [:]
    private var receivedThrough: [AudioSide: Int64] = [:]
    private var failedSides = Set<AudioSide>()
    public private(set) var droppedThrough: [AudioSide: Int64] = [:]

    public init(maximumSamples: Int = 524_288, beginFrame: Int64 = 0, maximumLossIntervals: Int = 1024) {
        precondition(maximumSamples > 0 && beginFrame >= 0 && (1...10_000).contains(maximumLossIntervals))
        self.maximumSamples = maximumSamples
        self.beginFrame = beginFrame
        self.maximumLossIntervals = maximumLossIntervals
    }

    public mutating func append(_ packet: TimedAudio) {
        guard !failedSides.contains(packet.side), packet.samples.count <= maximumSamples else { return }
        let (next, overflow) = sequence.addingReportingOverflow(1)
        guard !overflow else {
            failedSides.formUnion(AudioSide.allCases)
            return
        }
        sequence = next
        receivedThrough[packet.side] = max(receivedThrough[packet.side] ?? 0, packet.endFrame)
        while samples > maximumSamples - packet.samples.count, !packets.isEmpty {
            let old = packets.removeFirst()
            samples -= old.samples.count
            droppedThrough[old.side] = max(droppedThrough[old.side] ?? 0, old.endFrame)
            recordEviction(old)
        }
        guard !failedSides.contains(packet.side) else { return }
        packets.append(packet)
        samples += packet.samples.count
    }

    public func packets(after frame: Int64) -> [TimedAudio] {
        packets.compactMap { $0.after(frame) }.sorted { $0.startFrame < $1.startFrame }
    }

    /// Packets and exact pending loss ranges come from one serialized history state.
    public mutating func snapshot(acknowledging frames: [AudioSide: Int64] = [:]) -> AudioHistorySnapshot {
        packets = packets.compactMap { $0.after(max(0, frames[$0.side] ?? 0)) }
        samples = packets.reduce(0) { $0 + $1.samples.count }
        for side in AudioSide.allCases {
            let frame = max(0, frames[side] ?? 0)
            evicted[side] = evicted[side, default: []].compactMap { range in
                let start = max(frame, range.startFrame)
                guard range.endFrame > start else { return nil }
                return try? SessionInterval(startFrame: start, frames: range.endFrame - start)
            }
        }
        return AudioHistorySnapshot(
            id: id, sequence: sequence, beginFrame: beginFrame,
            packets: packets.sorted { $0.startFrame < $1.startFrame }, evicted: evicted,
            receivedThrough: receivedThrough, failedSides: failedSides)
    }

    /// The caller must commit an attached result on the same queue, without awaiting or flushing a tail.
    public mutating func prepareAttachment(
        expectedID: UUID, acknowledging frames: [AudioSide: Int64], supportedSides: Set<AudioSide>
    ) -> AudioHistoryAttachment {
        guard id == expectedID else { return .obsolete }
        let snapshot = snapshot(acknowledging: frames)
        if !snapshot.failedSides.isDisjoint(with: supportedSides)
            || snapshot.packets.contains(where: { supportedSides.contains($0.side) })
            || supportedSides.contains(where: { !snapshot.evicted[$0, default: []].isEmpty })
        {
            return .retry(snapshot)
        }
        return .attached
    }

    private mutating func recordEviction(_ packet: TimedAudio) {
        guard !failedSides.contains(packet.side),
            let interval = try? SessionInterval(
                startFrame: packet.startFrame, frames: packet.endFrame - packet.startFrame)
        else { return }
        var ranges = evicted[packet.side, default: []] + [interval]
        ranges.sort { $0.startFrame < $1.startFrame }
        var merged: [SessionInterval] = []
        for range in ranges {
            if let last = merged.last, range.startFrame <= last.endFrame,
                let combined = try? SessionInterval(
                    startFrame: last.startFrame, frames: max(last.endFrame, range.endFrame) - last.startFrame)
            {
                merged[merged.count - 1] = combined
            } else {
                merged.append(range)
            }
        }
        guard merged.count <= maximumLossIntervals else {
            failedSides.insert(packet.side)
            packets.removeAll { $0.side == packet.side }
            samples = packets.reduce(0) { $0 + $1.samples.count }
            return
        }
        evicted[packet.side] = merged
    }
}

public struct AudioHistorySnapshot: Sendable {
    public let id: UUID
    public let sequence: UInt64
    public let beginFrame: Int64
    public let packets: [TimedAudio]
    public let evicted: [AudioSide: [SessionInterval]]
    public let receivedThrough: [AudioSide: Int64]
    public let failedSides: Set<AudioSide>
}

public enum AudioHistoryAttachment: Sendable {
    case attached
    case retry(AudioHistorySnapshot)
    case obsolete
}

/// The sequence is captured on the audio queue before the recorder's file queue is checkpointed.
/// It proves which received packets have already been offered to the recorder, even with delayed timestamps.
public struct TranscriptReplayCheckpoint: Sendable {
    public let historyID: UUID
    public let sequence: UInt64
    public let manifest: RecordingManifest?
    public let directory: URL?

    public init(historyID: UUID, sequence: UInt64, manifest: RecordingManifest?, directory: URL?) throws {
        try manifest?.validate()
        self.historyID = historyID
        self.sequence = sequence
        self.manifest = manifest
        self.directory = directory
    }
}

public struct TranscriptHandoffStep: Sendable {
    public enum Source: Equatable, Sendable { case recording, buffered, gap, silence }
    public let side: AudioSide
    public let startFrame: Int64
    public let endFrame: Int64
    public let source: Source
    public let samples: [Float]
}

public enum TranscriptHandoffWork: Sendable {
    case checkpointRequired
    case step(TranscriptHandoffStep)
    case complete
}

/// A cursor is an acknowledged coverage frontier, not the largest packet timestamp seen.
/// Every earlier interval has been supplied, persisted as missing, or proved empty by one atomic snapshot.
public struct TranscriptHandoffReducer: Sendable {
    public private(set) var cursors: [AudioSide: Int64]

    public init(startingAt frame: Int64) throws {
        guard frame >= 0, frame <= TranscriptLimits.maximumFrame else { throw TranscriptFailure.invalidAudio }
        cursors = Dictionary(uniqueKeysWithValues: AudioSide.allCases.map { ($0, frame) })
    }

    public func next(
        in snapshot: AudioHistorySnapshot, checkpoint: TranscriptReplayCheckpoint?,
        supportedSides: Set<AudioSide>
    ) throws -> TranscriptHandoffWork {
        let sides = supportedSides.subtracting(snapshot.failedSides)
        guard !sides.isEmpty else { return .complete }
        guard let checkpoint, checkpoint.historyID == snapshot.id else { return .checkpointRequired }
        if checkpoint.sequence < snapshot.sequence,
            sides.contains(where: { side in
                snapshot.evicted[side, default: []].contains { $0.endFrame > cursors[side, default: 0] }
            })
        {
            return .checkpointRequired
        }
        let candidates = try AudioSide.allCases.filter { sides.contains($0) }.compactMap {
            try nextStep(side: $0, snapshot: snapshot, checkpoint: checkpoint)
        }
        guard let step = candidates.min(by: { $0.startFrame < $1.startFrame }) else { return .complete }
        return .step(step)
    }

    public mutating func acknowledge(_ step: TranscriptHandoffStep) throws {
        guard step.startFrame == cursors[step.side], step.endFrame > step.startFrame,
            step.endFrame <= TranscriptLimits.maximumFrame
        else { throw TranscriptFailure.invalidAudio }
        cursors[step.side] = step.endFrame
    }

    private func nextStep(
        side: AudioSide, snapshot: AudioHistorySnapshot, checkpoint: TranscriptReplayCheckpoint
    ) throws -> TranscriptHandoffStep? {
        let cursor = cursors[side, default: 0]
        let segments = checkpoint.manifest?.segments ?? []
        let beforeBuffering =
            segments.lazy.filter { $0.side == side && $0.startFrame < snapshot.beginFrame }
            .map { min($0.startFrame + $0.frames, snapshot.beginFrame) }.max() ?? 0
        let horizon = max(beforeBuffering, snapshot.receivedThrough[side, default: 0])
        guard horizon <= TranscriptLimits.maximumFrame else { throw TranscriptFailure.invalidAudio }
        guard cursor < horizon else { return nil }
        let packetEnd = min(horizon, cursor + 4800)
        let packets = snapshot.packets.filter { $0.side == side }
        if let packet = packets.first(where: { $0.startFrame <= cursor && $0.endFrame > cursor }) {
            let end = min(packetEnd, packet.endFrame)
            let lower = Int(cursor - packet.startFrame) * 2
            let upper = lower + Int(end - cursor) * 2
            return TranscriptHandoffStep(
                side: side, startFrame: cursor, endFrame: end, source: .buffered,
                samples: Array(packet.samples[lower..<upper]))
        }
        if let end = segments.lazy.filter({
            $0.side == side && $0.startFrame <= cursor && $0.startFrame + $0.frames > cursor
        })
        .map({ $0.startFrame + $0.frames }).max() {
            return TranscriptHandoffStep(
                side: side, startFrame: cursor, endFrame: min(packetEnd, end), source: .recording, samples: []
            )
        }
        let loss = snapshot.evicted[side, default: []].first {
            $0.startFrame <= cursor && $0.endFrame > cursor
        }
        var next = horizon
        for segment in segments where segment.side == side && segment.startFrame > cursor {
            next = min(next, segment.startFrame)
        }
        for packet in packets where packet.startFrame > cursor { next = min(next, packet.startFrame) }
        for range in snapshot.evicted[side, default: []] where range.startFrame > cursor {
            next = min(next, range.startFrame)
        }
        if let loss { next = min(next, loss.endFrame) }
        return TranscriptHandoffStep(
            side: side, startFrame: cursor, endFrame: next, source: loss == nil ? .silence : .gap, samples: []
        )
    }
}
