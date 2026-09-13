public struct StereoTimeline: Sendable {
    private var samples: [Float]
    private var positions: [Int64]
    private let capacity: Int
    public init(capacity: Int = 96_000) {
        precondition(capacity > 0)
        self.capacity = capacity
        samples = .init(repeating: 0, count: capacity * 2)
        positions = .init(repeating: -1, count: capacity)
    }
    public mutating func insert(_ input: [Float], at start: Int64) {
        guard start >= 0 else { return }
        for frame in 0..<input.count / 2 {
            let absolute = start + Int64(frame)
            let slot = Int(absolute % Int64(capacity))
            samples[slot * 2] = input[frame * 2]
            samples[slot * 2 + 1] = input[frame * 2 + 1]
            positions[slot] = absolute
        }
    }
    public func read(at start: Int64, frames: Int) -> [Float] {
        guard frames > 0 else { return [] }
        var result = [Float](repeating: 0, count: frames * 2)
        for frame in 0..<frames {
            let absolute = start + Int64(frame)
            guard absolute >= 0 else { continue }
            let slot = Int(absolute % Int64(capacity))
            if positions[slot] == absolute {
                result[frame * 2] = samples[slot * 2]
                result[frame * 2 + 1] = samples[slot * 2 + 1]
            }
        }
        return result
    }
}
