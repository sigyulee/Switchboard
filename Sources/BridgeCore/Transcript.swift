import Foundation

public enum TranscriptFailure: String, Error, LocalizedError, Sendable {
    case invalidConfiguration, invalidEntry, invalidAudio, invalidPath, capacityExceeded, staleSession
    case unavailableFormat, alreadyRunning

    public var errorDescription: String? { "Transcript: \(rawValue)" }
}

public enum TranscriptLimits {
    public static let maximumTextBytes = 32_768
    public static let maximumEntries = 10_000
    public static let maximumGaps = 10_000
    public static let maximumFileBytes = 16_777_216
    public static let maximumFrame: Int64 = 48_000 * 60 * 60 * 24 * 30
}

public struct TranscriptConfiguration: Codable, Hashable, Sendable {
    public let callerLocaleIdentifier: String
    public let agentLocaleIdentifier: String
    public let targetLocaleIdentifier: String

    public init(callerLocaleIdentifier: String, agentLocaleIdentifier: String, targetLocaleIdentifier: String)
        throws
    {
        self.callerLocaleIdentifier = try Self.normalized(callerLocaleIdentifier)
        self.agentLocaleIdentifier = try Self.normalized(agentLocaleIdentifier)
        self.targetLocaleIdentifier = try Self.normalized(targetLocaleIdentifier)
    }

    public func validate() throws {
        _ = try Self.normalized(callerLocaleIdentifier)
        _ = try Self.normalized(agentLocaleIdentifier)
        _ = try Self.normalized(targetLocaleIdentifier)
    }

    public func sourceLocaleIdentifier(for side: AudioSide) -> String {
        side == .caller ? callerLocaleIdentifier : agentLocaleIdentifier
    }

    public func skipsTranslation(for side: AudioSide) -> Bool {
        Self.languageKey(sourceLocaleIdentifier(for: side)) == Self.languageKey(targetLocaleIdentifier)
    }

    public static func languageKey(_ identifier: String) -> String {
        let language = Locale.Language(identifier: identifier.replacingOccurrences(of: "_", with: "-"))
        return [language.languageCode?.identifier ?? "", language.script?.identifier ?? ""].joined(
            separator: "-")
    }

    private static func normalized(_ value: String) throws -> String {
        let value = value.replacingOccurrences(of: "_", with: "-")
        guard (2...64).contains(value.utf8.count),
            value.utf8.allSatisfy({
                (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45
            }),
            let first = value.split(separator: "-", omittingEmptySubsequences: false).first,
            (2...8).contains(first.count), first.allSatisfy(\.isLetter),
            !value.contains("--"), !value.hasSuffix("-"),
            Locale.Language(identifier: value).languageCode != nil
        else { throw TranscriptFailure.invalidConfiguration }
        return Locale.identifier(.bcp47, from: value)
    }
}

public struct TranscriptSessionToken: Hashable, Sendable {
    public let sessionID: UUID
    public let generation: UUID
    public init(sessionID: UUID, generation: UUID = UUID()) {
        self.sessionID = sessionID
        self.generation = generation
    }
}

public enum TranscriptTranslationStatus: String, Codable, Sendable {
    case notRequested, notNeeded, pending, translated, downloadRequired, unsupported, failed, dropped,
        interrupted
}

public struct TranscriptEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var side: AudioSide
    public var startFrame: Int64
    public var endFrame: Int64
    public var original: String
    public var isFinal: Bool
    public var translation: String?
    public var translationStatus: TranscriptTranslationStatus

    public init(
        id: UUID = UUID(), side: AudioSide, startFrame: Int64, endFrame: Int64, original: String,
        isFinal: Bool, translation: String? = nil,
        translationStatus: TranscriptTranslationStatus = .notRequested
    ) {
        self.id = id
        self.side = side
        self.startFrame = startFrame
        self.endFrame = endFrame
        self.original = original
        self.isFinal = isFinal
        self.translation = translation
        self.translationStatus = translationStatus
    }

    public func validate() throws {
        guard startFrame >= 0, endFrame >= startFrame, endFrame <= TranscriptLimits.maximumFrame,
            !original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            original.utf8.count <= TranscriptLimits.maximumTextBytes,
            translation.map({ !$0.isEmpty && $0.utf8.count <= TranscriptLimits.maximumTextBytes }) ?? true,
            (translationStatus == .translated) == (translation != nil),
            isFinal || (translation == nil && translationStatus == .notRequested)
        else { throw TranscriptFailure.invalidEntry }
    }
}

public struct TranscriptGap: Codable, Equatable, Sendable {
    public let side: AudioSide
    public let startFrame: Int64
    public let endFrame: Int64
    public let droppedPackets: UInt64
    public let reason: String

    public init(
        side: AudioSide, startFrame: Int64, endFrame: Int64, droppedPackets: UInt64 = 1, reason: String
    ) {
        self.side = side
        self.startFrame = startFrame
        self.endFrame = endFrame
        self.droppedPackets = droppedPackets
        self.reason = reason
    }

    public func validate() throws {
        guard startFrame >= 0, endFrame >= startFrame, endFrame <= TranscriptLimits.maximumFrame,
            droppedPackets > 0, !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            reason.utf8.count <= 2048
        else { throw TranscriptFailure.invalidEntry }
    }
}

public enum TranscriptModelState: String, Codable, Sendable {
    case ready, notNeeded, downloadRequired, unsupported, resourceLimit, failed, stopped
}

public struct TranscriptSideState: Equatable, Sendable {
    public let side: AudioSide
    public var speech: TranscriptModelState
    public var translation: TranscriptModelState
    public var message: String?
    public init(
        side: AudioSide, speech: TranscriptModelState, translation: TranscriptModelState,
        message: String? = nil
    ) {
        self.side = side
        self.speech = speech
        self.translation = translation
        self.message = message
    }
}

public enum TranscriptEvent: Sendable {
    case partial(TranscriptEntry)
    case final(TranscriptEntry)
    case upsert(TranscriptEntry)
    case gap(TranscriptGap)
    case state(TranscriptSideState)
}
