import Foundation

public enum SessionManifestError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedVersion, invalidDate, invalidSampleRate, unfinishedSession

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion: "This session version is not supported."
        case .invalidDate: "The session date is invalid."
        case .invalidSampleRate: "The session sample rate is invalid."
        case .unfinishedSession: "End the session before saving its completed package."
        }
    }
}

/// Stored as session.json beside the unchanged v1 audio manifest.json.
public struct SessionManifest: Codable, Equatable, Identifiable, Sendable {
    public static let packageExtension = "switchboard"
    public static let filename = "session.json"
    public let version: Int
    public let sampleRate: Int64
    public var state: SessionState
    public let createdAt: Date
    public var isDraft: Bool
    public var id: UUID { state.id }
    public var title: String { state.name }
    public var description: String { state.description }
    public var durationFrames: Int64 { state.durationFrames }

    public init(state: SessionState, createdAt: Date = .now, isDraft: Bool = true) throws {
        version = 1
        sampleRate = SessionState.sampleRate
        self.state = state
        self.createdAt = createdAt
        self.isDraft = isDraft
        try validate()
    }

    public func validate() throws {
        guard version == 1 else { throw SessionManifestError.unsupportedVersion }
        guard sampleRate == SessionState.sampleRate else { throw SessionManifestError.invalidSampleRate }
        guard createdAt.timeIntervalSinceReferenceDate.isFinite else {
            throw SessionManifestError.invalidDate
        }
        try state.validate()
        guard isDraft || state.lifecycle == .ended else { throw SessionManifestError.unfinishedSession }
    }

    private enum CodingKeys: CodingKey { case version, sampleRate, state, createdAt, isDraft }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        sampleRate = try values.decode(Int64.self, forKey: .sampleRate)
        state = try values.decode(SessionState.self, forKey: .state)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        isDraft = try values.decode(Bool.self, forKey: .isDraft)
        try validate()
    }
}
