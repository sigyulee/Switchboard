import Foundation

/// Missing audio reported for one source, with overlapping intervals counted only once in the duration.
public struct RecordingGapSummary: Equatable, Sendable {
    public let side: AudioSide
    /// Original gap details in chronological order, retaining metadata order for equal start frames.
    public let gaps: [AudioGap]
    public let sampleRate: Double
    /// The length of the interval union, bounded by the validated recording duration.
    public let totalFrames: Int64
    /// The number of original reports, including overlapping or duplicate intervals.
    public var intervalCount: Int { gaps.count }
    public var duration: TimeInterval { Double(totalFrames) / sampleRate }

    /// Validates the entire manifest before summarizing the selected source.
    ///
    /// Throws `RecordingManifestError` for invalid metadata. After validation, sorting costs
    /// O(n log n) time and O(n) space for the selected source's n original gap reports.
    public init(manifest: RecordingManifest, side: AudioSide) throws {
        try manifest.validate()
        self.side = side
        sampleRate = manifest.sampleRate
        gaps = manifest.gaps.enumerated()
            .filter { $0.element.side == side }
            .sorted {
                if $0.element.startFrame == $1.element.startFrame { return $0.offset < $1.offset }
                return $0.element.startFrame < $1.element.startFrame
            }
            .map(\.element)

        var coveredEnd: Int64 = 0
        var unavailableFrames: Int64 = 0
        for gap in gaps {
            // Validation bounds each end and the union length within durationFrames, including Int64.max.
            let end = gap.startFrame + gap.frames
            guard end > coveredEnd else { continue }
            unavailableFrames += end - max(coveredEnd, gap.startFrame)
            coveredEnd = end
        }
        totalFrames = unavailableFrames
    }
}
