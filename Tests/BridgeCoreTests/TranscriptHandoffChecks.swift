import BridgeCore
import Foundation
import TranscriptKit

struct TranscriptHandoffChecks {
    func recordedEvictionRequiresANewerCheckpointBeforeReplay() throws {
        var history = AudioHistory(maximumSamples: 4)
        let stale = try checkpoint(history, ranges: [.caller: [(0, 2)]], duration: 100)
        try history.append(packet(.caller, 0, 2))
        try history.append(packet(.caller, 2, 4))
        let snapshot = history.snapshot()
        var reducer = try TranscriptHandoffReducer(startingAt: 0)
        guard
            case .checkpointRequired = try reducer.next(
                in: snapshot, checkpoint: stale, supportedSides: [.caller])
        else {
            throw CheckFailure(description: "a stale file snapshot classified newer eviction")
        }
        let fresh = try checkpoint(history, ranges: [.caller: [(0, 4)]])
        let output = try drain(&reducer, snapshot: snapshot, checkpoint: fresh, sides: [.caller])
        try expect(output.frames[.caller] == [0, 1, 2, 3])
        try expect(output.gaps.isEmpty && reducer.cursors[.caller] == 4)
    }

    func unrecordedEvictionPersistsOnlyTheActualMissingInterval() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "handoff-gap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID()
        let journal = try TranscriptJournal(sessionID: id, directory: directory)
        let token = await journal.beginGeneration()
        var history = AudioHistory(maximumSamples: 4)
        try history.append(packet(.caller, 10, 12))
        try history.append(packet(.caller, 20, 22))
        var reducer = try TranscriptHandoffReducer(startingAt: 0)
        let output = try drain(
            &reducer, snapshot: history.snapshot(), checkpoint: checkpoint(history), sides: [.caller])
        try expect(output.frames[.caller] == [20, 21])
        try expect(output.gaps.count == 1 && output.gaps[0].startFrame == 10 && output.gaps[0].endFrame == 12)
        for gap in output.gaps { try await expectGapSaved(journal, gap, token) }
        let reloaded = try TranscriptJournal(sessionID: id, directory: directory)
        let storedGaps = await reloaded.gaps()
        try expect(storedGaps == output.gaps)
        try expect(
            Set(FileManager.default.contentsOfDirectory(atPath: directory.path)) == ["transcript.json"])
    }

    func toggledRecordingUnionsDiskAndPreviouslyAcceptedLiveAudio() throws {
        var history = AudioHistory(maximumSamples: 4)
        var reducer = try TranscriptHandoffReducer(startingAt: 0)
        try history.append(packet(.caller, 0, 2))
        var result = try drain(
            &reducer, snapshot: history.snapshot(), checkpoint: checkpoint(history), sides: [.caller])
        try history.append(packet(.caller, 2, 4))
        let second = try drain(
            &reducer, snapshot: history.snapshot(), checkpoint: checkpoint(history), sides: [.caller])
        result.merge(second)
        try history.append(packet(.caller, 4, 6))
        try history.append(packet(.caller, 6, 8))
        try history.append(packet(.caller, 8, 10))
        let snapshot = history.snapshot(acknowledging: reducer.cursors)
        let disk = try checkpoint(history, ranges: [.caller: [(0, 2), (4, 6), (8, 10)]])
        result.merge(try drain(&reducer, snapshot: snapshot, checkpoint: disk, sides: [.caller]))
        try expect(result.frames[.caller] == [0, 1, 2, 3, 4, 5, 8, 9])
        try expect(result.gaps.count == 1 && result.gaps[0].startFrame == 6 && result.gaps[0].endFrame == 8)
    }

    func evictionBetweenSnapshotAndAcknowledgementDoesNotLoseAcceptedAudio() throws {
        var history = AudioHistory(maximumSamples: 4)
        try history.append(packet(.caller, 0, 2))
        let snapshot = history.snapshot()
        let disk = try checkpoint(history)
        try history.append(packet(.caller, 2, 4))
        var reducer = try TranscriptHandoffReducer(startingAt: 0)
        let first = try drain(&reducer, snapshot: snapshot, checkpoint: disk, sides: [.caller])
        try expect(first.frames[.caller] == [0, 1])
        let later = history.snapshot(acknowledging: reducer.cursors)
        try expect(later.evicted[.caller, default: []].isEmpty)
        let second = try drain(&reducer, snapshot: later, checkpoint: disk, sides: [.caller])
        try expect(second.frames[.caller] == [2, 3] && second.gaps.isEmpty)
    }

    func atomicAttachmentRetriesForNewTailAndRejectsStaleHistory() throws {
        var history = AudioHistory(maximumSamples: 8)
        try history.append(packet(.caller, 0, 2))
        let snapshot = history.snapshot()
        var reducer = try TranscriptHandoffReducer(startingAt: 0)
        _ = try drain(&reducer, snapshot: snapshot, checkpoint: checkpoint(history), sides: [.caller])
        try history.append(packet(.caller, 2, 4))
        guard
            case .retry(let tail) = history.prepareAttachment(
                expectedID: snapshot.id, acknowledging: reducer.cursors, supportedSides: [.caller])
        else {
            throw CheckFailure(description: "live attachment skipped the concurrent tail")
        }
        let output = try drain(&reducer, snapshot: tail, checkpoint: checkpoint(history), sides: [.caller])
        try expect(output.frames[.caller] == [2, 3])
        guard
            case .attached = history.prepareAttachment(
                expectedID: snapshot.id, acknowledging: reducer.cursors, supportedSides: [.caller])
        else {
            throw CheckFailure(description: "fully accounted tail did not attach")
        }
        var replacement = AudioHistory()
        try replacement.append(packet(.caller, 4, 6))
        guard
            case .obsolete = replacement.prepareAttachment(
                expectedID: snapshot.id, acknowledging: reducer.cursors, supportedSides: [.caller])
        else {
            throw CheckFailure(description: "an obsolete producer modified replacement history")
        }
        try expect(replacement.snapshot().packets.count == 1)
    }

    func perSpeakerFrontiersNeverDuplicateOrReorderPackets() throws {
        var history = AudioHistory(maximumSamples: 24)
        try history.append(packet(.caller, 0, 4))
        try history.append(packet(.agent, 1, 3))
        try history.append(packet(.caller, 2, 6))
        var reducer = try TranscriptHandoffReducer(startingAt: 0)
        let snapshot = history.snapshot()
        let output = try drain(
            &reducer, snapshot: snapshot, checkpoint: checkpoint(history), sides: [.caller, .agent])
        try expect(output.frames[.caller] == [0, 1, 2, 3, 4, 5])
        try expect(output.frames[.agent] == [1, 2])
        try expect(output.gaps.isEmpty)
        try expect(reducer.cursors[.caller] == 6 && reducer.cursors[.agent] == 3)
        let repeatOutput = try drain(
            &reducer, snapshot: snapshot, checkpoint: checkpoint(history), sides: [.caller, .agent])
        try expect(repeatOutput.frames.isEmpty && repeatOutput.gaps.isEmpty)
    }

    func lossMetadataCapacityFailureIsBoundedAndSourceLocal() throws {
        var history = AudioHistory(maximumSamples: 2, maximumLossIntervals: 2)
        for start in [Int64(0), 10, 20, 30] { try history.append(packet(.caller, start, start + 1)) }
        try history.append(packet(.agent, 40, 41))
        let snapshot = history.snapshot()
        try expect(snapshot.failedSides == [.caller])
        try expect(snapshot.evicted[.caller, default: []].count <= 2)
        var reducer = try TranscriptHandoffReducer(startingAt: 0)
        let output = try drain(
            &reducer, snapshot: snapshot, checkpoint: checkpoint(history), sides: [.caller, .agent])
        try expect(output.frames[.agent] == [40] && output.frames[.caller] == nil)
        try expect(output.gaps.isEmpty)
    }

    private struct Output {
        var frames: [AudioSide: [Int64]] = [:]
        var gaps: [TranscriptGap] = []
        mutating func merge(_ other: Self) {
            for (side, values) in other.frames { frames[side, default: []] += values }
            gaps += other.gaps
        }
    }

    private func drain(
        _ reducer: inout TranscriptHandoffReducer, snapshot: AudioHistorySnapshot,
        checkpoint: TranscriptReplayCheckpoint, sides: Set<AudioSide>
    ) throws -> Output {
        var output = Output()
        for _ in 0..<1000 {
            switch try reducer.next(in: snapshot, checkpoint: checkpoint, supportedSides: sides) {
            case .checkpointRequired: throw CheckFailure(description: "unexpected stale checkpoint")
            case .complete: return output
            case .step(let step):
                switch step.source {
                case .recording:
                    output.frames[step.side, default: []] += Array(step.startFrame..<step.endFrame)
                case .buffered:
                    let samples = step.samples
                    let expected = (step.startFrame..<step.endFrame).flatMap { [Float($0), -Float($0)] }
                    try expect(samples == expected)
                    output.frames[step.side, default: []] += Array(step.startFrame..<step.endFrame)
                case .gap:
                    output.gaps.append(
                        TranscriptGap(
                            side: step.side, startFrame: step.startFrame, endFrame: step.endFrame,
                            reason: "live audio buffer overflow"))
                case .silence: break
                }
                try reducer.acknowledge(step)
            }
        }
        throw CheckFailure(description: "handoff reducer did not converge")
    }

    private func checkpoint(
        _ history: AudioHistory, ranges: [AudioSide: [(Int64, Int64)]] = [:], duration: Int64 = 0
    ) throws -> TranscriptReplayCheckpoint {
        var manifest = RecordingManifest(title: "Handoff disk provider", owner: .manual)
        manifest.durationFrames = duration
        for (side, ranges) in ranges {
            for (index, range) in ranges.enumerated() {
                manifest.segments.append(
                    RecordingSegment(
                        side: side, filename: "\(side.rawValue)-\(index).caf", startFrame: range.0,
                        frames: range.1 - range.0))
                manifest.durationFrames = max(manifest.durationFrames, range.1)
            }
        }
        return try TranscriptReplayCheckpoint(
            historyID: history.id, sequence: history.sequence, manifest: manifest, directory: nil)
    }

    private func packet(_ side: AudioSide, _ start: Int64, _ end: Int64) throws -> TimedAudio {
        try TimedAudio(
            side: side, samples: (start..<end).flatMap { [Float($0), -Float($0)] }, startFrame: start)
    }

    private func expectGapSaved(
        _ journal: TranscriptJournal, _ gap: TranscriptGap, _ token: TranscriptSessionToken
    ) async throws {
        let saved = try await journal.recordGap(gap, token: token)
        try expect(saved)
    }
}
