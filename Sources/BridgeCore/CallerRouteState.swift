import Foundation

public enum CallerRouteStatus: String, Equatable, Sendable {
    case unknown, waiting, connected, disconnected
}

public enum CallerRouteIssue: Error, Equatable, Sendable {
    case unavailableDevices, unverifiedProcesses, unstableProcessList, indirectDevice
    case unsupportedProperty, invalidPropertySize, invalidEvidence, invalidClock
    case queryFailed(Int32)
}

/// Evidence about the selected caller's required virtual devices. Audio amplitude
/// and physical monitor availability deliberately have no representation here.
public struct CallerRouteEvidence: Equatable, Sendable {
    public let verifiedProcessCount: Int?
    public let speakerAssociated: Bool?
    public let microphoneAssociated: Bool?
    /// Active I/O in a verified process associated with the required speaker bus.
    public let isRunningOutput: Bool?
    /// Active I/O in a verified process associated with the required microphone bus.
    public let isRunningInput: Bool?
    public let issue: CallerRouteIssue?

    public init(
        verifiedProcessCount: Int?, speakerAssociated: Bool?, microphoneAssociated: Bool?,
        isRunningOutput: Bool?, isRunningInput: Bool?, issue: CallerRouteIssue? = nil
    ) {
        self.verifiedProcessCount = verifiedProcessCount
        self.speakerAssociated = speakerAssociated
        self.microphoneAssociated = microphoneAssociated
        self.isRunningOutput = isRunningOutput
        self.isRunningInput = isRunningInput
        self.issue = issue
    }

    public static func unknown(_ issue: CallerRouteIssue) -> Self {
        Self(
            verifiedProcessCount: nil, speakerAssociated: nil, microphoneAssociated: nil,
            isRunningOutput: nil, isRunningInput: nil, issue: issue)
    }

    fileprivate var isComplete: Bool {
        guard issue == nil, let count = verifiedProcessCount, count >= 0,
            let speakerAssociated, let microphoneAssociated, let isRunningOutput, let isRunningInput
        else { return false }
        return count > 0
            || (!speakerAssociated && !microphoneAssociated && !isRunningOutput && !isRunningInput)
    }
}

/// A conservative route-membership reducer, not a telephony or speech detector.
/// Disconnected remains latched until reset, including when route evidence returns.
public struct CallerRouteState: Equatable, Sendable {
    public static let debounceSeconds: TimeInterval = 2
    public private(set) var sessionID: UUID?
    public private(set) var callerID: String?
    public private(set) var epoch: UUID?
    public private(set) var status: CallerRouteStatus = .waiting
    public private(set) var evidence: CallerRouteEvidence = .unknown(.unverifiedProcesses)
    public private(set) var isArmed = false
    private var lastTime: TimeInterval?
    private var lossBeganAt: TimeInterval?

    public init() {}

    /// Call on a new session, caller selection, or explicit Resume. The returned
    /// epoch must accompany samples; an earlier observation cannot rearm this one.
    @discardableResult
    public mutating func reset(sessionID: UUID, callerID: String) -> UUID {
        let epoch = UUID()
        self = Self()
        self.sessionID = sessionID
        self.callerID = callerID
        self.epoch = epoch
        return epoch
    }

    @discardableResult
    public mutating func observe(
        _ sample: CallerRouteEvidence, at time: TimeInterval, epoch: UUID
    ) -> CallerRouteStatus {
        guard self.epoch == epoch, sessionID != nil, callerID?.isEmpty == false else { return status }
        evidence = sample
        guard time.isFinite, time >= 0, lastTime.map({ time >= $0 }) ?? true else {
            evidence = .unknown(.invalidClock)
            lossBeganAt = nil
            if status != .disconnected { status = .unknown }
            return status
        }
        lastTime = time
        guard status != .disconnected else { return status }
        guard sample.isComplete else {
            lossBeganAt = nil
            status = .unknown
            return status
        }
        if sample.speakerAssociated == true, sample.microphoneAssociated == true {
            lossBeganAt = nil
            if sample.isRunningOutput == true, sample.isRunningInput == true { isArmed = true }
            status = isArmed ? .connected : .waiting
        } else if isArmed {
            if let lossBeganAt, time - lossBeganAt >= Self.debounceSeconds {
                status = .disconnected
            } else {
                if lossBeganAt == nil { lossBeganAt = time }
                status = .waiting
            }
        } else {
            lossBeganAt = nil
            status = .waiting
        }
        return status
    }
}
