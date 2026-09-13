import Foundation

/// Timestamped peak envelope. Missing buckets are silence, never synthetic motion.
public struct LiveWaveformHistory: Sendable {
    public static let count = 64
    private static let interval = 0.05
    private var peaks = [Float](repeating: 0, count: count)
    private var stamps = [Int64](repeating: .min, count: count)

    public init() {}

    public mutating func insert(peak: Float, seconds: Double) {
        guard seconds.isFinite, seconds >= 0, peak.isFinite else { return }
        let stamp = Int64(floor(seconds / Self.interval))
        let index = Int(stamp % Int64(Self.count))
        let value = peak < 0.0001 ? 0 : min(1, max(0, peak))
        peaks[index] = stamps[index] == stamp ? max(peaks[index], value) : value
        stamps[index] = stamp
    }

    public func samples(endingAt seconds: Double) -> [Float] {
        guard seconds.isFinite, seconds >= 0 else { return [Float](repeating: 0, count: Self.count) }
        let end = Int64(floor(seconds / Self.interval))
        return (0..<Self.count).map { offset in
            let stamp = end - Int64(Self.count - 1 - offset)
            guard stamp >= 0 else { return 0 }
            let index = Int(stamp % Int64(Self.count))
            return stamps[index] == stamp ? peaks[index] : 0
        }
    }
}
