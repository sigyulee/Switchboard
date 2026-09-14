import BridgeCore
import Foundation
import Synchronization

public struct TranscriptStartupContext: Equatable, Sendable {
    public let operation: UUID
    public let presentation: UUID
    public let sessionID: UUID?
    public init(operation: UUID, presentation: UUID, sessionID: UUID?) {
        self.operation = operation
        self.presentation = presentation
        self.sessionID = sessionID
    }
}

public struct TranscriptStartupAuthorization: Equatable, Sendable {
    fileprivate let id: UUID
    fileprivate let context: TranscriptStartupContext
}

/// Authorization is revoked synchronously by OFF/selection, independently of task cancellation delivery.
@MainActor public final class TranscriptStartupGate {
    private var current: TranscriptStartupAuthorization?
    private var revision = UUID()
    public init() {}

    public func begin(context: TranscriptStartupContext) -> TranscriptStartupAuthorization {
        let authorization = TranscriptStartupAuthorization(id: UUID(), context: context)
        current = authorization
        revision = authorization.id
        return authorization
    }

    @discardableResult public func invalidate() -> UUID {
        current = nil
        revision = UUID()
        return revision
    }

    public func isCurrentRevocation(_ revision: UUID) -> Bool { current == nil && self.revision == revision }

    public func permits(_ authorization: TranscriptStartupAuthorization, context: TranscriptStartupContext)
        -> Bool
    {
        current == authorization && authorization.context == context && context.sessionID != nil
    }

    public func require(_ authorization: TranscriptStartupAuthorization, context: TranscriptStartupContext)
        throws
    {
        try Task.checkCancellation()
        guard permits(authorization, context: context) else { throw CancellationError() }
    }

    public func wait<Value: Sendable>(
        _ authorization: TranscriptStartupAuthorization,
        context: @MainActor () -> TranscriptStartupContext,
        operation: @MainActor () async throws -> Value
    ) async throws -> Value {
        try require(authorization, context: context())
        do {
            let value = try await operation()
            try require(authorization, context: context())
            return value
        } catch {
            // A stale failing prerequisite must not run the active generation's error cleanup.
            try require(authorization, context: context())
            throw error
        }
    }
}

public struct TranscriptDeliveryReceipt: Equatable, Sendable {
    public let intervals: [AudioSide: [SessionInterval]]
    public let acceptedThrough: [AudioSide: Int64]
    /// Delivery continues, but checkpoint calculation stays conservative if coverage metadata fills up.
    public let truncatedSources: Set<AudioSide>
}

/// Installed readiness is independent of successful stop events and transient run failures.
public struct TranscriptReadinessState: Sendable {
    public private(set) var configuration: TranscriptConfiguration?
    public private(set) var installedStates: [AudioSide: TranscriptSideState] = [:]
    public init() {}

    public mutating func updateCapabilities(
        _ states: [AudioSide: TranscriptSideState], configuration: TranscriptConfiguration
    ) {
        self.configuration = configuration
        installedStates = states
    }

    public mutating func observeRunState(_ state: TranscriptSideState, configuration: TranscriptConfiguration)
    {
        if self.configuration != configuration {
            self.configuration = configuration
            installedStates = [:]
        }
        switch state.speech {
        case .ready, .downloadRequired, .unsupported: installedStates[state.side] = state
        case .stopped, .failed, .resourceLimit, .notNeeded: break
        }
    }

    public func canStart(configuration: TranscriptConfiguration?, busy: Bool, stopping: Bool) -> Bool {
        configuration != nil && configuration == self.configuration && !busy && !stopping
            && installedStates.values.contains { $0.speech == .ready }
    }
}

public struct TranscriptAudioPacket: Sendable {
    public let samples: [Float]
    public let startFrame: Int64
    public let endFrame: Int64
    public init(samples: [Float], startFrame: Int64, maximumFrames: Int = 4800) throws {
        let frames = samples.count / 2
        let (end, overflow) = startFrame.addingReportingOverflow(Int64(frames))
        guard maximumFrames > 0, maximumFrames <= 48_000, frames > 0, frames <= maximumFrames,
            samples.count.isMultiple(of: 2), samples.allSatisfy(\.isFinite),
            startFrame >= 0, !overflow, end <= TranscriptLimits.maximumFrame
        else { throw TranscriptFailure.invalidAudio }
        self.samples = samples
        self.startFrame = startFrame
        endFrame = end
    }
}

/// One bounded stream per source. Call from a Swift control queue, never a realtime callback.
public final class TranscriptFeeds: Sendable {
    private struct RecordedWaiter {
        let id: UUID
        let packet: TranscriptAudioPacket
        let continuation: CheckedContinuation<Bool, Never>
    }
    private struct State {
        var closed = false
        var closedSides = Set<AudioSide>()
        var dropped: [AudioSide: UInt64] = [:]
        var gaps: [AudioSide: [TranscriptGap]] = [:]
        var recorded: [AudioSide: RecordedWaiter] = [:]
        var accepted: [AudioSide: [SessionInterval]] = [:]
        var acceptedThrough: [AudioSide: Int64] = [:]
        var truncatedSources = Set<AudioSide>()
    }
    private let state = Mutex(State())
    let callerStream: AsyncStream<TranscriptAudioPacket>
    let agentStream: AsyncStream<TranscriptAudioPacket>
    private let caller: AsyncStream<TranscriptAudioPacket>.Continuation
    private let agent: AsyncStream<TranscriptAudioPacket>.Continuation
    private let maximumPacketFrames: Int

    public init(maximumBufferedPackets: Int = 16, maximumPacketFrames: Int = 4800) {
        precondition((1...256).contains(maximumBufferedPackets) && (1...48_000).contains(maximumPacketFrames))
        self.maximumPacketFrames = maximumPacketFrames
        (callerStream, caller) = AsyncStream.makeStream(
            bufferingPolicy: .bufferingOldest(maximumBufferedPackets))
        (agentStream, agent) = AsyncStream.makeStream(
            bufferingPolicy: .bufferingOldest(maximumBufferedPackets))
    }

    @discardableResult public func append(side: AudioSide, samples: [Float], startFrame: Int64) -> Bool {
        let packet = try? TranscriptAudioPacket(
            samples: samples, startFrame: startFrame, maximumFrames: maximumPacketFrames)
        return state.withLock { state in
            guard !state.closed, !state.closedSides.contains(side) else { return false }
            guard let packet else {
                recordDrop(
                    side: side, start: max(0, min(startFrame, TranscriptLimits.maximumFrame)),
                    end: max(0, min(startFrame, TranscriptLimits.maximumFrame)),
                    reason: "invalid audio packet", state: &state)
                return false
            }
            guard state.recorded[side] == nil else {
                recordDrop(
                    side: side, start: packet.startFrame, end: packet.endFrame,
                    reason: "live audio arrived while recorded audio was backpressured", state: &state)
                return false
            }
            switch (side == .caller ? caller : agent).yield(packet) {
            case .enqueued:
                recordAcceptance(packet, side: side, state: &state)
                return true
            case .dropped:
                recordDrop(
                    side: side, start: packet.startFrame, end: packet.endFrame,
                    reason: "transcription input queue full", state: &state)
                return false
            case .terminated: return false
            @unknown default: return false
            }
        }
    }

    /// One replay producer per side may wait for space. Never call this from an audio callback.
    public func appendRecorded(side: AudioSide, samples: [Float], startFrame: Int64) async -> Bool {
        guard
            let packet = try? TranscriptAudioPacket(
                samples: samples, startFrame: startFrame,
                maximumFrames: maximumPacketFrames)
        else { return false }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let immediate: Bool? = state.withLock { state in
                    guard !Task.isCancelled, !state.closed, !state.closedSides.contains(side),
                        state.recorded[side] == nil
                    else { return false }
                    switch (side == .caller ? caller : agent).yield(packet) {
                    case .enqueued:
                        recordAcceptance(packet, side: side, state: &state)
                        return true
                    case .dropped:
                        state.recorded[side] = RecordedWaiter(
                            id: id, packet: packet, continuation: continuation)
                        return nil
                    case .terminated: return false
                    @unknown default: return false
                    }
                }
                if let immediate { continuation.resume(returning: immediate) }
            }
        } onCancel: {
            self.cancelRecorded(side: side, id: id)
        }
    }

    public func finish() {
        let waiters: [RecordedWaiter] = state.withLock { state in
            guard !state.closed else { return [] }
            state.closed = true
            caller.finish()
            agent.finish()
            let waiters = Array(state.recorded.values)
            state.recorded.removeAll()
            return waiters
        }
        for waiter in waiters { waiter.continuation.resume(returning: false) }
    }
    func finish(side: AudioSide) {
        let waiter: RecordedWaiter? = state.withLock { state in
            state.closedSides.insert(side)
            (side == .caller ? caller : agent).finish()
            return state.recorded.removeValue(forKey: side)
        }
        waiter?.continuation.resume(returning: false)
    }
    public func droppedPacketCount(side: AudioSide) -> UInt64 {
        state.withLock { $0.dropped[side, default: 0] }
    }
    public func deliveryReceipt() -> TranscriptDeliveryReceipt {
        state.withLock {
            TranscriptDeliveryReceipt(
                intervals: $0.accepted, acceptedThrough: $0.acceptedThrough,
                truncatedSources: $0.truncatedSources)
        }
    }
    public func takeGaps(side: AudioSide) -> [TranscriptGap] {
        state.withLock { state in
            let result = state.gaps[side, default: []]
            state.gaps[side] = []
            return result
        }
    }
    func stream(for side: AudioSide) -> AsyncStream<TranscriptAudioPacket> {
        side == .caller ? callerStream : agentStream
    }

    func didConsume(side: AudioSide) {
        let completed: (RecordedWaiter, Bool)? = state.withLock { state in
            guard let waiter = state.recorded[side], !state.closed else { return nil }
            switch (side == .caller ? caller : agent).yield(waiter.packet) {
            case .enqueued:
                state.recorded[side] = nil
                recordAcceptance(waiter.packet, side: side, state: &state)
                return (waiter, true)
            case .terminated:
                state.recorded[side] = nil
                return (waiter, false)
            case .dropped: return nil
            @unknown default: return nil
            }
        }
        if let (waiter, accepted) = completed { waiter.continuation.resume(returning: accepted) }
    }

    private func cancelRecorded(side: AudioSide, id: UUID) {
        let waiter: RecordedWaiter? = state.withLock { state in
            guard state.recorded[side]?.id == id else { return nil }
            return state.recorded.removeValue(forKey: side)
        }
        waiter?.continuation.resume(returning: false)
    }

    private func recordDrop(side: AudioSide, start: Int64, end: Int64, reason: String, state: inout State) {
        let count = state.dropped[side, default: 0]
        state.dropped[side] = count == UInt64.max ? count : count + 1
        var gaps = state.gaps[side, default: []]
        if gaps.count < 32 {
            gaps.append(TranscriptGap(side: side, startFrame: start, endFrame: end, reason: reason))
        } else if let old = gaps.popLast() {
            gaps.append(
                TranscriptGap(
                    side: side, startFrame: min(old.startFrame, start), endFrame: max(old.endFrame, end),
                    droppedPackets: old.droppedPackets == UInt64.max ? UInt64.max : old.droppedPackets + 1,
                    reason: "additional transcription packets dropped within this interval"))
        }
        state.gaps[side] = gaps
    }

    private func recordAcceptance(_ packet: TranscriptAudioPacket, side: AudioSide, state: inout State) {
        state.acceptedThrough[side] = max(state.acceptedThrough[side, default: 0], packet.endFrame)
        guard !state.truncatedSources.contains(side),
            let interval = try? SessionInterval(
                startFrame: packet.startFrame, frames: packet.endFrame - packet.startFrame)
        else { return }
        var intervals = state.accepted[side, default: []] + [interval]
        intervals.sort { $0.startFrame < $1.startFrame }
        var merged: [SessionInterval] = []
        for interval in intervals {
            if let last = merged.last, interval.startFrame <= last.endFrame,
                let combined = try? SessionInterval(
                    startFrame: last.startFrame,
                    frames: max(last.endFrame, interval.endFrame) - last.startFrame)
            {
                merged[merged.count - 1] = combined
            } else {
                merged.append(interval)
            }
        }
        guard merged.count <= 1024 else {
            state.truncatedSources.insert(side)
            return
        }
        state.accepted[side] = merged
    }
}
