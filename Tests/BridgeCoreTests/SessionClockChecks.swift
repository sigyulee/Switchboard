import BridgeCore
import Foundation

struct SessionClockChecks {
    func contiguousPacketsIgnoreObservationQuantization() throws {
        let hostOrigin: UInt64 = 300_000_000_000_000
        let continuousOrigin = hostOrigin + 20_000_000_000_000
        let ticksPerFrame: UInt64 = 500
        var clock = try makeClock(host: hostOrigin, continuous: continuousOrigin)
        for index in 0..<1000 {
            let expected = Int64(index * 512)
            let packet = hostOrigin + UInt64(expected) * ticksPerFrame
            let observation = packet + 512 * ticksPerFrame + (index.isMultiple(of: 2) ? 100 : 300)
            // Vary both fractional-frame observation times and time between clock reads.
            let delay = UInt64(index % 7) * 170
            let continuous = observation + delay + continuousOrigin - hostOrigin
            try expect(
                clock.observe(
                    hostBefore: observation, continuous: continuous,
                    hostAfter: observation + delay + 80) == .unchanged)
            let actual = clock.frame(forHostTime: packet)
            guard actual == expected else {
                throw CheckFailure(
                    description:
                        "contiguous packet \(index): expected \(expected), got \(String(describing: actual))")
            }
        }

        // Nanosecond timestamps cannot represent every 48 kHz frame boundary exactly.
        var nanoseconds = try makeClock(
            host: hostOrigin, continuous: hostOrigin, numerator: 1, denominator: 1)
        for index in 0..<1000 {
            let expected = UInt64(index * 512)
            let packet = hostOrigin + expected * 1_000_000_000 / 48_000
            let observation = packet + 20_000_000 + UInt64(index % 5) * 5000
            try expect(
                nanoseconds.observe(
                    hostBefore: observation, continuous: observation + 500,
                    hostAfter: observation + 1000) == .unchanged)
            try expect(nanoseconds.frame(forHostTime: packet) == Int64(expected))
        }
    }

    func genuinePacketLossAndPauseRemainOnTheTimeline() throws {
        let origin: UInt64 = 1_000_000
        var clock = try makeClock(host: origin, continuous: origin + 100_000)
        let starts = [0, 512, 1536, 2048]
        let mapped = starts.compactMap { clock.frame(forHostTime: origin + UInt64($0) * 500) }
        try expect(mapped == starts.map(Int64.init))
        try expect(mapped[2] - (mapped[1] + 512) == 512)

        // No packets arrive during a manual pause; the session clock must not close that interval.
        let resumed = origin + 2 * 24_000_000
        try expect(
            clock.observe(hostBefore: resumed, continuous: resumed + 100_000, hostAfter: resumed)
                == .unchanged)
        try expect(clock.frame(forHostTime: resumed) == 96_000)
        try expect(clock.elapsedFrame(atContinuousTime: resumed + 100_000) == 96_000)
    }

    func sleepAddsSilenceAndRejectsPacketsFromTheOldCorrelation() throws {
        let origin: UInt64 = 300_000_000_000_000
        let offset: UInt64 = 20_000_000_000_000
        var clock = try makeClock(host: origin, continuous: origin + offset)
        let awake = origin + 24_000_000
        try expect(clock.frame(forHostTime: awake) == 48_000)
        let sleep: UInt64 = 5 * 24_000_000
        try expect(
            clock.observe(
                hostBefore: awake, continuous: awake + offset + sleep, hostAfter: awake) == .sleep)
        try expect(clock.frame(forHostTime: awake) == 288_000)
        try expect(clock.frame(forHostTime: awake + 512 * 500) == 288_512)
        try expect(clock.elapsedFrame(atContinuousTime: awake + offset + sleep) == 288_000)
        try expect(clock.frame(forHostTime: awake - 1) == nil)

        let again = awake + 24_000_000
        try expect(
            clock.observe(
                hostBefore: again, continuous: again + offset + sleep, hostAfter: again) == .unchanged)
        try expect(clock.frame(forHostTime: again) == 336_000)
    }

    func preemptionAndNarrowerBracketsNeverMoveTheStableAnchor() throws {
        let host: UInt64 = 1_000_000
        let offset: UInt64 = 5_000_000
        guard
            var clock = SessionAudioClock(
                hostBefore: host, continuous: host + offset + 300, hostAfter: host + 1000,
                timebaseNumerator: 125, timebaseDenominator: 3)
        else { throw CheckFailure(description: "valid initial bracket rejected") }
        let packet = host + 100_000
        let initial = clock.frame(forHostTime: packet)
        try expect(initial == 199)
        let later = host + 200_000
        // Refinement excludes the initial midpoint, but cannot rewrite its established mapping.
        try expect(
            clock.observe(hostBefore: later, continuous: later + offset, hostAfter: later) == .unchanged)
        try expect(clock.frame(forHostTime: packet) == initial)

        let preempted = later + 10_000
        try expect(
            clock.observe(
                hostBefore: preempted, continuous: preempted + offset + 24_000_000,
                hostAfter: preempted + 48_000_000) == .unchanged)
        try expect(clock.frame(forHostTime: packet) == initial)
        try expect(clock.frame(forHostTime: packet + 512 * 500) == initial! + 512)
    }

    func independentSourcesKeepTheirOffsetsAndRoundOnlyOnce() throws {
        let origin = UInt64.max - 20_000_000
        let clock = try makeClock(host: origin, continuous: origin)
        for index in 0..<20 {
            let caller = origin + UInt64(index * 512) * 500
            let agent = caller + 137 * 500
            try expect(clock.frame(forHostTime: caller) == Int64(index * 512))
            try expect(clock.frame(forHostTime: agent) == Int64(index * 512 + 137))
        }
        try expect(clock.frame(forHostTime: origin + 249) == 0)
        try expect(clock.frame(forHostTime: origin + 250) == 1)
        try expect(clock.frame(forHostTime: origin - 249) == 0)
        try expect(clock.frame(forHostTime: origin - 250) == -1)
        try expect(clock.frame(forHostTime: origin - 512 * 500) == -512)
        try expect(clock.elapsedFrame(atContinuousTime: origin + 499) == 0)
        try expect(clock.elapsedFrame(atContinuousTime: origin + 500) == 1)
    }

    func invalidObservationsAndArithmeticBoundsFailWithoutChangingTheClock() throws {
        for (before, continuous, after, numerator, denominator, rate) in [
            (UInt64(20), UInt64(30), UInt64(10), UInt32(125), UInt32(3), UInt32(48_000)),
            (20, 19, 30, 125, 3, 48_000),
            (20, 30, 40, 0, 3, 48_000),
            (20, 30, 40, 125, 0, 48_000),
            (20, 30, 40, 125, 3, 0),
        ] {
            try expect(
                SessionAudioClock(
                    hostBefore: before, continuous: continuous, hostAfter: after,
                    timebaseNumerator: numerator, timebaseDenominator: denominator, sampleRate: rate) == nil)
        }
        var clock = try makeClock(host: 10_000, continuous: 20_000)
        for (before, continuous, after) in [
            (UInt64(20_000), UInt64(30_000), UInt64(19_999)),
            (9999, 20_001, 10_001),
            (10_001, 19_999, 10_002),
            (20_000, 29_999, 20_000),
        ] {
            try expect(
                clock.observe(hostBefore: before, continuous: continuous, hostAfter: after) == .invalid)
            try expect(clock.frame(forHostTime: 10_000 + 512 * 500) == 512)
        }
        try expect(clock.elapsedFrame(atContinuousTime: 19_999) == nil)

        guard
            let large = SessionAudioClock(
                hostBefore: 0, continuous: 0, hostAfter: 0,
                timebaseNumerator: .max, timebaseDenominator: 1, sampleRate: .max),
            let negative = SessionAudioClock(
                hostBefore: .max, continuous: .max, hostAfter: .max,
                timebaseNumerator: .max, timebaseDenominator: 1, sampleRate: .max)
        else { throw CheckFailure(description: "positive timebase rejected") }
        try expect(large.frame(forHostTime: .max) == nil)
        try expect(large.elapsedFrame(atContinuousTime: .max) == nil)
        try expect(negative.frame(forHostTime: 0) == nil)
        try expect(large.frame(forHostTime: 0) == 0)

        // The product fits Int128 here, but the rounded result is still outside Int64.
        let unrepresentable = try makeClock(host: 0, continuous: 0, numerator: .max, denominator: 1)
        try expect(unrepresentable.frame(forHostTime: .max) == nil)

        guard
            let oneFramePerTick = SessionAudioClock(
                hostBefore: 0, continuous: 0, hostAfter: 0,
                timebaseNumerator: 1_000_000_000, timebaseDenominator: 1, sampleRate: 1),
            let negativeLimit = SessionAudioClock(
                hostBefore: UInt64(Int64.max) + 1, continuous: UInt64(Int64.max) + 1,
                hostAfter: UInt64(Int64.max) + 1,
                timebaseNumerator: 1_000_000_000, timebaseDenominator: 1, sampleRate: 1)
        else { throw CheckFailure(description: "unit frame timebase rejected") }
        try expect(oneFramePerTick.frame(forHostTime: UInt64(Int64.max)) == Int64.max)
        try expect(oneFramePerTick.frame(forHostTime: UInt64(Int64.max) + 1) == nil)
        try expect(negativeLimit.frame(forHostTime: 0) == Int64.min)
    }

    private func makeClock(
        host: UInt64, continuous: UInt64, numerator: UInt32 = 125, denominator: UInt32 = 3
    ) throws -> SessionAudioClock {
        guard
            let clock = SessionAudioClock(
                hostBefore: host, continuous: continuous, hostAfter: host,
                timebaseNumerator: numerator, timebaseDenominator: denominator)
        else { throw CheckFailure(description: "valid session clock rejected") }
        return clock
    }
}
