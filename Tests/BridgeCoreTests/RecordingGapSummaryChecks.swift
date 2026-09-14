import BridgeCore
import Foundation

struct RecordingGapSummaryChecks {
    func overlappingUnorderedGapsPreserveDetailsAndCountUnavailableFramesOnce() throws {
        var manifest = RecordingManifest(title: "Gap summary", owner: .manual)
        manifest.durationFrames = 120_000
        manifest.gaps = [
            AudioGap(side: .caller, startFrame: 48_000, frames: 24_000, reason: "Later loss"),
            AudioGap(side: .agent, startFrame: 0, frames: 48_000, reason: "Other source"),
            AudioGap(side: .caller, startFrame: 12_000, frames: 24_000, reason: "Overlapping loss"),
            AudioGap(side: .caller, startFrame: 18_000, frames: 6000, reason: "Nested loss"),
            AudioGap(side: .caller, startFrame: 0, frames: 24_000, reason: "First loss"),
            AudioGap(side: .caller, startFrame: 12_000, frames: 24_000, reason: "Duplicate report"),
            AudioGap(side: .caller, startFrame: 96_000, frames: 1, reason: "Final frame"),
        ]

        let summary = try RecordingGapSummary(manifest: manifest, side: .caller)
        try expect(summary.intervalCount == 6)
        try expect(summary.totalFrames == 60_001)
        try expect(abs(summary.duration - 1.2500208333333334) < 0.000000000001)
        try expect(summary.sampleRate == 48_000)
        try expect(summary.side == .caller)
        try expect(
            summary.gaps == [
                manifest.gaps[4], manifest.gaps[2], manifest.gaps[5], manifest.gaps[3],
                manifest.gaps[0], manifest.gaps[6],
            ])
    }

    func eachSourceHasItsOwnSummaryAndMissingMetadataStaysEmpty() throws {
        var manifest = RecordingManifest(title: "Separate source gaps", owner: .manual)
        manifest.durationFrames = 48_000
        manifest.gaps = [
            AudioGap(side: .caller, startFrame: 0, frames: 24_000, reason: "Caller loss"),
            AudioGap(side: .agent, startFrame: 0, frames: 12_000, reason: "Agent loss"),
            AudioGap(side: .agent, startFrame: 6000, frames: 12_000, reason: "Agent overlap"),
        ]
        let caller = try RecordingGapSummary(manifest: manifest, side: .caller)
        let agent = try RecordingGapSummary(manifest: manifest, side: .agent)
        try expect(caller.totalFrames == 24_000)
        try expect(caller.intervalCount == 1)
        try expect(agent.totalFrames == 18_000)
        try expect(agent.intervalCount == 2)
        try expect(agent.side == .agent)
        try expect(agent.gaps == [manifest.gaps[1], manifest.gaps[2]])

        manifest.gaps = [manifest.gaps[0]]
        let noAgentGaps = try RecordingGapSummary(manifest: manifest, side: .agent)
        try expect(noAgentGaps.gaps.isEmpty)
        try expect(noAgentGaps.intervalCount == 0)
        try expect(noAgentGaps.totalFrames == 0)
        try expect(noAgentGaps.duration == 0)

        let empty = RecordingManifest(title: "Empty recording", owner: .manual)
        for side in AudioSide.allCases {
            let summary = try RecordingGapSummary(manifest: empty, side: side)
            try expect(summary.gaps.isEmpty)
            try expect(summary.totalFrames == 0)
            try expect(summary.duration == 0)
        }
    }

    func adjacentAndSingleFrameIntervalsRetainSubMillisecondDurations() throws {
        var manifest = RecordingManifest(title: "Tiny gaps", owner: .manual)
        manifest.durationFrames = 5
        manifest.gaps = [
            AudioGap(side: .caller, startFrame: 4, frames: 1, reason: "Isolated frame"),
            AudioGap(side: .caller, startFrame: 2, frames: 1, reason: "Adjacent frame"),
            AudioGap(side: .caller, startFrame: 1, frames: 1, reason: "First frame"),
        ]
        let summary = try RecordingGapSummary(manifest: manifest, side: .caller)
        try expect(summary.intervalCount == 3)
        try expect(summary.totalFrames == 3)
        try expect(abs(summary.duration - 0.0000625) < 0.000000000001)
        try expect(summary.gaps.map(\.startFrame) == [1, 2, 4])

        manifest.durationFrames = 1
        manifest.gaps = [AudioGap(side: .agent, startFrame: 0, frames: 1, reason: "One frame")]
        let oneFrame = try RecordingGapSummary(manifest: manifest, side: .agent)
        try expect(oneFrame.totalFrames == 1)
        try expect(abs(oneFrame.duration - 0.000020833333333333333) < 0.000000000001)
    }

    func maximumTimelineBoundsDoNotOverflowOrFillAvailableFrames() throws {
        var manifest = RecordingManifest(title: "Maximum timeline", owner: .manual)
        manifest.durationFrames = .max
        manifest.gaps = [
            AudioGap(side: .caller, startFrame: 0, frames: .max, reason: "Full loss"),
            AudioGap(side: .caller, startFrame: 0, frames: .max, reason: "Duplicate full loss"),
            AudioGap(side: .caller, startFrame: .max - 1, frames: 1, reason: "Last frame"),
        ]
        let full = try RecordingGapSummary(manifest: manifest, side: .caller)
        try expect(full.totalFrames == .max)
        try expect(full.intervalCount == 3)
        try expect(full.duration.isFinite)

        manifest.gaps = [
            AudioGap(side: .caller, startFrame: .max - 1, frames: 1, reason: "Last frame"),
            AudioGap(side: .caller, startFrame: 0, frames: .max - 2, reason: "Earlier loss"),
            AudioGap(side: .caller, startFrame: 5, frames: 7, reason: "Nested report"),
        ]
        let almostFull = try RecordingGapSummary(manifest: manifest, side: .caller)
        try expect(almostFull.totalFrames == .max - 1)
    }

    func invalidManifestMetadataIsRejectedBeforeSummarizingEitherSource() throws {
        var manifest = RecordingManifest(title: "Invalid gap metadata", owner: .manual)
        manifest.durationFrames = .max
        for gap in [
            AudioGap(side: .caller, startFrame: -1, frames: 1, reason: "Negative start"),
            AudioGap(side: .caller, startFrame: 0, frames: 0, reason: "Empty interval"),
            AudioGap(side: .caller, startFrame: 1, frames: -1, reason: "Negative length"),
            AudioGap(side: .caller, startFrame: .max, frames: 1, reason: "Overflow"),
            AudioGap(side: .caller, startFrame: 1, frames: .max, reason: "Overflow"),
        ] {
            manifest.gaps = [gap]
            try expectRejected(manifest, error: .invalidTimeline)
        }
        manifest.durationFrames = 10
        manifest.gaps = [AudioGap(side: .caller, startFrame: 10, frames: 1, reason: "Beyond duration")]
        try expectRejected(manifest, error: .invalidTimeline)
        manifest.gaps = []
        manifest.durationFrames = -1
        try expectRejected(manifest, error: .invalidTimeline)
        manifest.durationFrames = 0
        for sampleRate in [0.0, -48_000, 44_100, .nan, .infinity] {
            manifest.sampleRate = sampleRate
            try expectRejected(manifest, error: .invalidSampleRate)
        }
        manifest.sampleRate = 48_000
        manifest.version = 2
        try expectRejected(manifest, error: .unsupportedVersion)
        manifest.version = 1
        manifest.createdAt = Date(timeIntervalSinceReferenceDate: .infinity)
        try expectRejected(manifest, error: .invalidTimeline)
        manifest.createdAt = Date(timeIntervalSinceReferenceDate: 0)
        manifest.durationFrames = 1
        manifest.segments = [
            RecordingSegment(side: .agent, filename: "../escaped.caf", startFrame: 0, frames: 1)
        ]
        try expectRejected(manifest, error: .invalidSegment)
    }

    private func expectRejected(_ manifest: RecordingManifest, error expected: RecordingManifestError) throws
    {
        for side in AudioSide.allCases {
            do {
                _ = try RecordingGapSummary(manifest: manifest, side: side)
                throw CheckFailure(description: "Invalid manifest produced a gap summary")
            } catch let error as RecordingManifestError {
                try expect(error == expected)
            }
        }
    }
}
