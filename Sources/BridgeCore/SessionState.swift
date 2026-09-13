import Foundation

public enum SessionLifecycle: String, Codable, Sendable { case idle, running, paused, ended }
public enum SessionPauseReason: String, Codable, Sendable { case manual, callerDisconnected, routeFailure }

public enum SessionStateError: Error, Equatable, LocalizedError, Sendable {
    case invalidTransition, invalidTimestamp, invalidText, invalidInterval

    public var errorDescription: String? {
        switch self {
        case .invalidTransition: "This session action is not available in its current state."
        case .invalidTimestamp: "The session timing is invalid."
        case .invalidText: "The session name or description is invalid or too long."
        case .invalidInterval: "The session intervals are damaged."
        }
    }
}

/// A half-open interval on the session's 48 kHz timeline.
public struct SessionInterval: Codable, Equatable, Sendable {
    public let startFrame: Int64
    public let frames: Int64
    public var endFrame: Int64 { startFrame + frames }

    public init(startFrame: Int64, frames: Int64) throws {
        let (_, overflow) = startFrame.addingReportingOverflow(frames)
        guard startFrame >= 0, frames > 0, !overflow else { throw SessionStateError.invalidInterval }
        self.startFrame = startFrame
        self.frames = frames
    }

    private enum CodingKeys: CodingKey { case startFrame, frames }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            startFrame: values.decode(Int64.self, forKey: .startFrame),
            frames: values.decode(Int64.self, forKey: .frames))
    }
}

/// The caller supplies monotonic, session-relative frames, including time spent paused.
/// Adjacent enabled intervals are merged; time outside them remains silence or a text gap.
public struct SessionState: Codable, Equatable, Identifiable, Sendable {
    public static let sampleRate: Int64 = 48_000
    public let id: UUID
    public let name: String
    public let description: String
    public private(set) var lifecycle: SessionLifecycle = .idle
    public private(set) var pauseReason: SessionPauseReason?
    public private(set) var audioRecording = true
    public private(set) var transcription = false
    public private(set) var durationFrames: Int64 = 0
    public private(set) var recordingIntervals: [SessionInterval] = []
    public private(set) var transcriptionIntervals: [SessionInterval] = []

    public var effectiveAudioRecording: Bool { lifecycle == .running && audioRecording }
    public var effectiveTranscription: Bool { lifecycle == .running && transcription }

    public init(id: UUID = UUID(), name: String, description: String = "") throws {
        self.id = id
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.description = description
        try validate()
    }

    /// Repeating the current lifecycle action leaves its state and timestamp unchanged.
    public mutating func start(at frame: Int64 = 0) throws {
        if lifecycle == .running { return }
        guard lifecycle == .idle else { throw SessionStateError.invalidTransition }
        guard frame >= 0 else { throw SessionStateError.invalidTimestamp }
        durationFrames = frame
        lifecycle = .running
    }

    public mutating func pause(at frame: Int64, reason: SessionPauseReason = .manual) throws {
        if lifecycle == .paused { return }
        guard lifecycle == .running else { throw SessionStateError.invalidTransition }
        try advance(to: frame)
        lifecycle = .paused
        pauseReason = reason
    }

    public mutating func resume(at frame: Int64) throws {
        if lifecycle == .running { return }
        guard lifecycle == .paused else { throw SessionStateError.invalidTransition }
        try advance(to: frame)
        lifecycle = .running
        pauseReason = nil
    }

    public mutating func end(at frame: Int64) throws {
        if lifecycle == .ended { return }
        guard lifecycle == .running || lifecycle == .paused else { throw SessionStateError.invalidTransition }
        try advance(to: frame)
        lifecycle = .ended
        pauseReason = nil
    }

    public mutating func setAudioRecording(_ enabled: Bool, at frame: Int64) throws {
        try advance(to: frame)
        audioRecording = enabled
    }

    public mutating func setTranscription(_ enabled: Bool, at frame: Int64) throws {
        try advance(to: frame)
        transcription = enabled
    }

    /// Reconcile a cancelled asynchronous activation with the original OFF request.
    /// Audio recording and the session clock are independent of this correction.
    public mutating func reconcileTranscriptionOff(at frame: Int64) throws {
        guard transcription else { return }
        guard lifecycle == .running || lifecycle == .paused, frame >= 0, frame <= durationFrames else {
            throw SessionStateError.invalidTimestamp
        }
        transcriptionIntervals = try transcriptionIntervals.compactMap { interval in
            guard interval.startFrame < frame else { return nil }
            return try SessionInterval(
                startFrame: interval.startFrame, frames: min(interval.endFrame, frame) - interval.startFrame)
        }
        transcription = false
    }

    public mutating func advance(by frames: Int64) throws {
        let (next, overflow) = durationFrames.addingReportingOverflow(frames)
        guard frames >= 0, !overflow else { throw SessionStateError.invalidTimestamp }
        try advance(to: next)
    }

    public mutating func advance(to frame: Int64) throws {
        guard lifecycle == .running || lifecycle == .paused else { throw SessionStateError.invalidTransition }
        guard frame >= durationFrames else { throw SessionStateError.invalidTimestamp }
        guard frame > durationFrames else { return }
        let interval = try SessionInterval(startFrame: durationFrames, frames: frame - durationFrames)
        if effectiveAudioRecording { try Self.append(interval, to: &recordingIntervals) }
        if effectiveTranscription { try Self.append(interval, to: &transcriptionIntervals) }
        durationFrames = frame
    }

    /// Close an interrupted draft after inspecting its durable audio. Unobserved time
    /// remains outside enabled intervals; recovery never resumes capture by itself.
    public func recovered(durationFrames: Int64) throws -> Self {
        guard durationFrames >= self.durationFrames else { throw SessionStateError.invalidTimestamp }
        var recovered = self
        recovered.lifecycle = .ended
        recovered.pauseReason = nil
        recovered.durationFrames = durationFrames
        try recovered.validate()
        return recovered
    }

    public func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            name.utf8.count <= 512, description.utf8.count <= 16_384,
            !name.contains("\0"), !description.contains("\0")
        else { throw SessionStateError.invalidText }
        guard durationFrames >= 0 else { throw SessionStateError.invalidTimestamp }
        guard (lifecycle == .paused) == (pauseReason != nil) else {
            throw SessionStateError.invalidTransition
        }
        if lifecycle == .idle {
            guard durationFrames == 0, recordingIntervals.isEmpty, transcriptionIntervals.isEmpty,
                audioRecording, !transcription
            else { throw SessionStateError.invalidTransition }
        }
        for intervals in [recordingIntervals, transcriptionIntervals] {
            var previousEnd: Int64 = 0
            for interval in intervals {
                guard interval.startFrame >= previousEnd, interval.endFrame <= durationFrames else {
                    throw SessionStateError.invalidInterval
                }
                previousEnd = interval.endFrame
            }
        }
    }

    private static func append(_ interval: SessionInterval, to intervals: inout [SessionInterval]) throws {
        if let last = intervals.last, last.endFrame == interval.startFrame {
            intervals[intervals.count - 1] = try SessionInterval(
                startFrame: last.startFrame, frames: interval.endFrame - last.startFrame)
        } else {
            intervals.append(interval)
        }
    }

    private enum CodingKeys: CodingKey {
        case id, name, description, lifecycle, pauseReason, audioRecording, transcription
        case durationFrames, recordingIntervals, transcriptionIntervals
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        description = try values.decode(String.self, forKey: .description)
        lifecycle = try values.decode(SessionLifecycle.self, forKey: .lifecycle)
        pauseReason = try values.decodeIfPresent(SessionPauseReason.self, forKey: .pauseReason)
        audioRecording = try values.decode(Bool.self, forKey: .audioRecording)
        transcription = try values.decode(Bool.self, forKey: .transcription)
        durationFrames = try values.decode(Int64.self, forKey: .durationFrames)
        recordingIntervals = try values.decode([SessionInterval].self, forKey: .recordingIntervals)
        transcriptionIntervals = try values.decode([SessionInterval].self, forKey: .transcriptionIntervals)
        try validate()
    }
}
