/// Correlates an audio host clock with a session clock that also advances during sleep.
/// Both clocks use the same supplied tick timebase. Read the host clock before and after
/// the continuous clock so scheduling delays produce an interval, not a false sleep jump.
public struct SessionAudioClock: Sendable {
    public enum Observation: Equatable, Sendable {
        case unchanged, sleep, invalid
    }

    private let continuousOrigin: UInt64
    private let numerator: Int128
    private let denominator: Int128
    private let sampleRate: Int128
    private var offsetLower: UInt64
    private var offsetUpper: UInt64
    private var stableOffset: UInt64
    private var lastHostAfter: UInt64
    private var lastContinuous: UInt64
    private var earliestHostAfterSleep: UInt64?

    public init?(
        hostBefore: UInt64, continuous: UInt64, hostAfter: UInt64,
        timebaseNumerator: UInt32, timebaseDenominator: UInt32, sampleRate: UInt32 = 48_000
    ) {
        guard hostBefore <= hostAfter, continuous >= hostBefore,
            timebaseNumerator > 0, timebaseDenominator > 0, sampleRate > 0
        else { return nil }
        continuousOrigin = continuous
        numerator = Int128(timebaseNumerator)
        denominator = Int128(timebaseDenominator) * 1_000_000_000
        self.sampleRate = Int128(sampleRate)
        offsetLower = continuous > hostAfter ? continuous - hostAfter : 0
        offsetUpper = continuous - hostBefore
        stableOffset = offsetLower + (offsetUpper - offsetLower) / 2
        lastHostAfter = hostAfter
        lastContinuous = continuous
    }

    /// Overlapping intervals refine the evidence without moving the established audio anchor.
    /// Only a disjoint increase establishes additional sleep. Invalid observations change nothing.
    @discardableResult
    public mutating func observe(hostBefore: UInt64, continuous: UInt64, hostAfter: UInt64) -> Observation {
        guard hostBefore <= hostAfter, hostBefore >= lastHostAfter,
            continuous >= hostBefore, continuous >= lastContinuous
        else { return .invalid }
        let lower = continuous > hostAfter ? continuous - hostAfter : 0
        let upper = continuous - hostBefore
        guard upper >= offsetLower else { return .invalid }
        let result: Observation
        if lower > offsetUpper {
            offsetLower = lower
            offsetUpper = upper
            stableOffset = lower + (upper - lower) / 2
            // The sleep boundary is not identifiable inside the gap between observations.
            // Do not relabel queued packets from the old correlation with this new offset.
            earliestHostAfterSleep = hostAfter
            result = .sleep
        } else {
            offsetLower = max(offsetLower, lower)
            offsetUpper = min(offsetUpper, upper)
            result = .unchanged
        }
        lastHostAfter = hostAfter
        lastContinuous = continuous
        return result
    }

    /// Returns a signed position so callers can trim a packet that begins before session start.
    /// After sleep, packets older than the confirming observation are ambiguous and return nil.
    public func frame(forHostTime hostTime: UInt64) -> Int64? {
        if let earliestHostAfterSleep, hostTime < earliestHostAfterSleep { return nil }
        let ticks = Int128(hostTime) + Int128(stableOffset) - Int128(continuousOrigin)
        return frames(forTicks: ticks, rounding: true)
    }

    /// Completed session frames, including sleep and explicit session pauses.
    public func elapsedFrame(atContinuousTime continuousTime: UInt64) -> Int64? {
        guard continuousTime >= continuousOrigin else { return nil }
        return frames(forTicks: Int128(continuousTime - continuousOrigin), rounding: false)
    }

    private func frames(forTicks ticks: Int128, rounding: Bool) -> Int64? {
        let scaled = ticks.multipliedReportingOverflow(by: numerator)
        guard !scaled.overflow else { return nil }
        let product = scaled.partialValue.multipliedReportingOverflow(by: sampleRate)
        guard !product.overflow else { return nil }
        var result = product.partialValue / denominator
        if rounding {
            let remainder = product.partialValue % denominator
            // The denominator is bounded by UInt32.max * 1e9, so doubling its remainder is safe.
            if abs(remainder) * 2 >= denominator { result += remainder < 0 ? -1 : 1 }
        }
        return Int64(exactly: result)
    }
}
