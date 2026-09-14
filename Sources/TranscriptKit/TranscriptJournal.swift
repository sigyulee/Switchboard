import BridgeCore
import Darwin
import Foundation

/// Final text is committed atomically. PCM and volatile text are never written here.
public actor TranscriptJournal {
    private struct Archive: Codable {
        var version = 1
        let sessionID: UUID
        var entries: [TranscriptEntry]
        var configuration: TranscriptConfiguration?
        var gaps: [TranscriptGap]
        var completedThrough: [String: Int64]?

        private enum CodingKeys: String, CodingKey {
            case version, sessionID, entries, configuration, gaps, completedThrough
        }

        init(
            sessionID: UUID, entries: [TranscriptEntry], configuration: TranscriptConfiguration?,
            gaps: [TranscriptGap], completedThrough: [String: Int64]? = nil
        ) {
            self.sessionID = sessionID
            self.entries = entries
            self.configuration = configuration
            self.gaps = gaps
            self.completedThrough = completedThrough
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decode(Int.self, forKey: .version)
            sessionID = try container.decode(UUID.self, forKey: .sessionID)
            completedThrough = try container.decodeIfPresent([String: Int64].self, forKey: .completedThrough)
            for (side, frame) in completedThrough ?? [:] {
                guard AudioSide(rawValue: side) != nil, frame >= 0, frame <= TranscriptLimits.maximumFrame
                else {
                    throw TranscriptFailure.invalidEntry
                }
            }
            configuration = try container.decodeIfPresent(
                TranscriptConfiguration.self, forKey: .configuration)
            try configuration?.validate()
            gaps = []
            if container.contains(.gaps), try !container.decodeNil(forKey: .gaps) {
                var values = try container.nestedUnkeyedContainer(forKey: .gaps)
                guard values.count.map({ $0 <= TranscriptLimits.maximumGaps }) ?? true else {
                    throw TranscriptFailure.capacityExceeded
                }
                while !values.isAtEnd {
                    guard gaps.count < TranscriptLimits.maximumGaps else {
                        throw TranscriptFailure.capacityExceeded
                    }
                    let gap = try values.decode(TranscriptGap.self)
                    try gap.validate()
                    gaps.append(gap)
                }
            }
            var values = try container.nestedUnkeyedContainer(forKey: .entries)
            guard values.count.map({ $0 <= TranscriptLimits.maximumEntries }) ?? true else {
                throw TranscriptFailure.capacityExceeded
            }
            entries = []
            while !values.isAtEnd {
                guard entries.count < TranscriptLimits.maximumEntries else {
                    throw TranscriptFailure.capacityExceeded
                }
                let entry = try values.decode(TranscriptEntry.self)
                try entry.validate()
                guard entry.isFinal else { throw TranscriptFailure.invalidEntry }
                entries.append(entry)
            }
        }
    }
    private let sessionID: UUID
    private let location: TranscriptJournalDirectory?
    private var token: TranscriptSessionToken?
    private var entries: [TranscriptEntry]
    private var configurationValue: TranscriptConfiguration?
    private var gapValues: [TranscriptGap] = []
    private var checkpointValues: [String: Int64]?

    public init(sessionID: UUID, directory: URL?) throws {
        self.sessionID = sessionID
        entries = []
        guard let directory else {
            location = nil
            return
        }
        let location = try TranscriptJournalDirectory(directory: directory, sessionID: sessionID)
        self.location = location
        if let data = try location.readTranscript() {
            let archive = try JSONDecoder().decode(Archive.self, from: data)
            guard archive.version == 1, archive.sessionID == sessionID,
                archive.entries.count <= TranscriptLimits.maximumEntries,
                Set(archive.entries.map(\.id)).count == archive.entries.count
            else { throw TranscriptFailure.invalidEntry }
            for entry in archive.entries {
                try entry.validate()
                guard entry.isFinal else { throw TranscriptFailure.invalidEntry }
            }
            entries = archive.entries.map { entry in
                var entry = entry
                if entry.translationStatus == .pending { entry.translationStatus = .interrupted }
                return entry
            }
            configurationValue = archive.configuration
            gapValues = archive.gaps
            checkpointValues = archive.completedThrough
        }
    }

    /// Metadata-only read. The caller places this synchronous operation on its owned file queue.
    public static func readArchive(sessionID: UUID, directory: URL) throws -> TranscriptArchiveSnapshot {
        let location = try TranscriptJournalDirectory(directory: directory, sessionID: sessionID)
        guard let data = try location.readTranscript() else {
            return try TranscriptArchiveSnapshot(
                sessionID: sessionID, entries: [], gaps: [], configuration: nil)
        }
        let archive = try JSONDecoder().decode(Archive.self, from: data)
        guard archive.version == 1, archive.sessionID == sessionID,
            Set(archive.entries.map(\.id)).count == archive.entries.count
        else { throw TranscriptFailure.invalidEntry }
        try location.validate()
        return try TranscriptArchiveSnapshot(
            sessionID: sessionID,
            entries: archive.entries.map { entry in
                var entry = entry
                if entry.translationStatus == .pending { entry.translationStatus = .interrupted }
                return entry
            }, gaps: archive.gaps, configuration: archive.configuration)
    }

    /// Persist language choices before beginning a generation. Changed choices invalidate old work.
    public func setConfiguration(_ configuration: TranscriptConfiguration) throws {
        try configuration.validate()
        guard configurationValue != configuration else { return }
        try persist(entries, configuration: configuration, gaps: gapValues)
        configurationValue = configuration
        invalidate()
    }

    public func configuration() -> TranscriptConfiguration? { configurationValue }
    public func gaps() -> [TranscriptGap] { gapValues }

    /// Older archives have no checkpoint field; completed final text provides a
    /// conservative fallback only until an explicit baseline has been persisted.
    public func completedThrough() -> [AudioSide: Int64] {
        Dictionary(
            uniqueKeysWithValues: AudioSide.allCases.map { side in
                let frame: Int64
                if let checkpointValues {
                    frame = checkpointValues[side.rawValue, default: 0]
                } else {
                    frame = entries.filter { $0.side == side && $0.isFinal }.map(\.endFrame).max() ?? 0
                }
                return (side, frame)
            })
    }

    @discardableResult public func prepareCheckpoints(
        durationFrames: Int64, token: TranscriptSessionToken
    ) throws -> Bool {
        guard self.token == token else { return false }
        let baseline = completedThrough()
        try validateCheckpoints(baseline, durationFrames: durationFrames)
        guard checkpointValues == nil else { return true }
        let updated = Dictionary(uniqueKeysWithValues: baseline.map { ($0.key.rawValue, $0.value) })
        try persist(entries, configuration: configurationValue, gaps: gapValues, completedThrough: updated)
        checkpointValues = updated
        return true
    }

    /// Accepted input advances only after that source's analyzer and result stream
    /// both drain successfully. An unsupported/failed/cancelled source stays retryable.
    @discardableResult public func commitCompletedThrough(
        _ accepted: [AudioSide: Int64], completion: TranscriptCompletion,
        durationFrames: Int64, token: TranscriptSessionToken
    ) throws -> Bool {
        guard self.token == token else { return false }
        try validateCheckpoints(accepted, durationFrames: durationFrames)
        var updated = completedThrough()
        try validateCheckpoints(updated, durationFrames: durationFrames)
        for (side, frame) in accepted {
            guard frame >= updated[side, default: 0] else { throw TranscriptFailure.invalidEntry }
            if completion.drainedSources.contains(side), !completion.wasCancelled {
                updated[side] = frame
            }
        }
        let encoded = Dictionary(uniqueKeysWithValues: updated.map { ($0.key.rawValue, $0.value) })
        try persist(entries, configuration: configurationValue, gaps: gapValues, completedThrough: encoded)
        checkpointValues = encoded
        return true
    }

    /// Live progress uses drained, actually enqueued coverage. A final timestamp envelope never
    /// proves that a recorded hole was delivered; the saved-job planner handles known text separately.
    @discardableResult public func commitLiveDelivery(
        _ receipt: TranscriptDeliveryReceipt, completion: TranscriptCompletion,
        recording: RecordingManifest, session: SessionManifest?, throughFrame: Int64,
        token: TranscriptSessionToken
    ) throws -> Bool {
        guard self.token == token else { return false }
        try recording.validate()
        guard recording.id == sessionID, throughFrame >= 0,
            throughFrame <= recording.durationFrames
        else { throw TranscriptFailure.invalidEntry }
        let baseline = completedThrough()
        let missing = try StoredTranscriptProcessor.eligibleIntervals(
            manifest: recording, session: session, completedThrough: baseline, finalEntries: [])
        var candidates: [AudioSide: Int64] = [:]
        for side in completion.drainedSources where !completion.wasCancelled {
            guard let acceptedEnd = receipt.acceptedThrough[side] else { continue }
            var candidate = min(acceptedEnd, throughFrame)
            let floor = baseline[side, default: 0]
            guard candidate >= floor else { continue }
            let delivered = receipt.intervals[side, default: []]
            for interval in missing[side, default: []] where interval.startFrame < candidate {
                var cursor = max(floor, interval.startFrame)
                let end = min(candidate, interval.endFrame)
                for accepted in delivered where accepted.endFrame > cursor && accepted.startFrame < end {
                    if accepted.startFrame > cursor { break }
                    cursor = max(cursor, min(end, accepted.endFrame))
                    if cursor == end { break }
                }
                if cursor < end {
                    candidate = cursor
                    break
                }
            }
            candidates[side] = candidate
        }
        return try commitCompletedThrough(
            candidates, completion: completion, durationFrames: recording.durationFrames, token: token)
    }

    private func validateCheckpoints(_ values: [AudioSide: Int64], durationFrames: Int64) throws {
        guard durationFrames >= 0, durationFrames <= TranscriptLimits.maximumFrame,
            values.values.allSatisfy({ $0 >= 0 && $0 <= durationFrames })
        else { throw TranscriptFailure.invalidEntry }
    }

    @discardableResult public func recordGap(_ gap: TranscriptGap, token: TranscriptSessionToken) throws
        -> Bool
    {
        guard self.token == token else { return false }
        try gap.validate()
        guard gapValues.count < TranscriptLimits.maximumGaps else { throw TranscriptFailure.capacityExceeded }
        let updated = gapValues + [gap]
        try persist(entries, configuration: configurationValue, gaps: updated)
        gapValues = updated
        return true
    }

    public func beginGeneration() -> TranscriptSessionToken {
        invalidate()
        let token = TranscriptSessionToken(sessionID: sessionID)
        self.token = token
        entries.removeAll { !$0.isFinal }
        return token
    }

    public func isCurrent(_ token: TranscriptSessionToken) -> Bool { self.token == token }
    public func invalidate() {
        token = nil
        entries.removeAll { !$0.isFinal }
        for index in entries.indices where entries[index].translationStatus == .pending {
            entries[index].translationStatus = .interrupted
        }
    }
    public func invalidate(token: TranscriptSessionToken) {
        guard self.token == token else { return }
        invalidate()
    }
    public func snapshot() -> [TranscriptEntry] { entries.sorted { $0.startFrame < $1.startFrame } }

    @discardableResult public func upsert(_ entry: TranscriptEntry, token: TranscriptSessionToken) throws
        -> Bool
    {
        guard self.token == token else { return false }
        try entry.validate()
        var updated = entries
        if let index = updated.firstIndex(where: { $0.id == entry.id }) {
            let old = updated[index]
            guard old.side == entry.side,
                !old.isFinal
                    || (entry.isFinal && entry.original == old.original && entry.startFrame == old.startFrame
                        && entry.endFrame == old.endFrame)
            else { return false }
            updated[index] = entry
        } else {
            guard updated.count < TranscriptLimits.maximumEntries else {
                throw TranscriptFailure.capacityExceeded
            }
            updated.append(entry)
        }
        guard
            updated.reduce(0, { $0 + $1.original.utf8.count + ($1.translation?.utf8.count ?? 0) })
                <= TranscriptLimits.maximumFileBytes / 2
        else { throw TranscriptFailure.capacityExceeded }
        if entry.isFinal { try persist(updated, configuration: configurationValue, gaps: gapValues) }
        entries = updated
        return true
    }

    @discardableResult public func updateTranslation(
        entryID: UUID, original: String, translation: String?,
        status: TranscriptTranslationStatus, token: TranscriptSessionToken
    ) throws -> Bool {
        guard self.token == token, var entry = entries.first(where: { $0.id == entryID }),
            entry.isFinal, entry.original == original
        else { return false }
        entry.translation = translation
        entry.translationStatus = status
        return try upsert(entry, token: token)
    }

    public func exportText() -> String {
        snapshot().filter(\.isFinal).map { entry in
            let milliseconds = entry.startFrame / 48
            let time = String(
                format: "%02lld:%02lld:%02lld.%03lld", milliseconds / 3_600_000,
                milliseconds / 60_000 % 60, milliseconds / 1000 % 60, milliseconds % 1000)
            var text = "[\(time)] \(entry.side == .caller ? "Caller" : "Agent"): \(entry.original)"
            if let translation = entry.translation { text += "\n  \(translation)" }
            return text
        }.joined(separator: "\n\n")
    }

    private func persist(
        _ updated: [TranscriptEntry], configuration: TranscriptConfiguration?, gaps: [TranscriptGap],
        completedThrough: [String: Int64]? = nil
    ) throws {
        guard let location else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(
            Archive(
                sessionID: sessionID, entries: updated.filter(\.isFinal),
                configuration: configuration, gaps: gaps,
                completedThrough: completedThrough ?? checkpointValues))
        guard data.count <= TranscriptLimits.maximumFileBytes else {
            throw TranscriptFailure.capacityExceeded
        }
        try location.commit(data)
    }
}

public struct TranscriptArchiveSnapshot: Sendable {
    public let sessionID: UUID
    public let entries: [TranscriptEntry]
    public let gaps: [TranscriptGap]
    public let configuration: TranscriptConfiguration?

    public init(
        sessionID: UUID, entries: [TranscriptEntry], gaps: [TranscriptGap],
        configuration: TranscriptConfiguration?
    ) throws {
        guard entries.count <= TranscriptLimits.maximumEntries, gaps.count <= TranscriptLimits.maximumGaps,
            entries.allSatisfy(\.isFinal), Set(entries.map(\.id)).count == entries.count
        else { throw TranscriptFailure.invalidEntry }
        for entry in entries { try entry.validate() }
        for gap in gaps { try gap.validate() }
        try configuration?.validate()
        self.sessionID = sessionID
        self.entries = entries.sorted { $0.startFrame < $1.startFrame }
        self.gaps = gaps
        self.configuration = configuration
    }
}

/// Session selection and archive loading use the same token as their displayed data.
public struct TranscriptPresentationState: Sendable {
    public private(set) var sessionID: UUID?
    public private(set) var selection = UUID()
    public var entries: [TranscriptEntry] = []
    public var gaps: [TranscriptGap] = []
    public var error: String?
    public var showConfiguration = true
    public var panelVisible = true
    public private(set) var archiveConfiguration: TranscriptConfiguration?

    public init() {}

    @discardableResult public mutating func select(sessionID: UUID, archived: Bool = false) -> UUID {
        self.sessionID = sessionID
        selection = UUID()
        entries = []
        gaps = []
        error = nil
        showConfiguration = !archived
        panelVisible = true
        archiveConfiguration = nil
        return selection
    }

    @discardableResult public mutating func apply(_ snapshot: TranscriptArchiveSnapshot, selection: UUID)
        -> Bool
    {
        guard self.selection == selection, sessionID == snapshot.sessionID else { return false }
        entries = snapshot.entries
        gaps = snapshot.gaps
        archiveConfiguration = snapshot.configuration
        showConfiguration = false
        error = nil
        return true
    }
}

/// The immutable directory descriptor anchors every write to the original directory vnode.
/// URL and ancestor identities are rechecked, but rename itself never resolves the package path.
private final class TranscriptJournalDirectory {
    private final class Descriptor {
        let value: Int32
        init(_ value: Int32) { self.value = value }
        deinit { close(value) }
    }
    private struct Identity: Equatable {
        let device: dev_t
        let inode: ino_t
        let kind: mode_t
        init(_ value: stat) {
            device = value.st_dev
            inode = value.st_ino
            kind = value.st_mode & mode_t(S_IFMT)
        }
    }
    private let handle: Descriptor
    private var descriptor: Int32 { handle.value }
    private let identity: Identity
    private let sessionID: UUID
    private let paths: [(String, Identity)]

    init(directory: URL, sessionID: UUID) throws {
        guard directory.isFileURL, directory.path.utf8.count <= 4096, !directory.path.contains("\0"),
            directory.query == nil, directory.fragment == nil,
            directory.host == nil || directory.host == "" || directory.host == "localhost"
        else { throw TranscriptFailure.invalidPath }
        let original = directory.standardizedFileURL
        let initial = try Self.pathIdentity(original.path)
        guard initial.kind == mode_t(S_IFDIR) else { throw TranscriptFailure.invalidPath }
        let canonical = original.resolvingSymlinksInPath()
        let descriptor = open(canonical.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw Self.posixError() }
        let handle = Descriptor(descriptor)
        do {
            var attributes = stat()
            guard fstat(descriptor, &attributes) == 0 else { throw Self.posixError() }
            let identity = Identity(attributes)
            guard identity == initial else { throw TranscriptFailure.staleSession }
            var paths: [(String, Identity)] = []
            for root in [original, canonical] {
                var path = root
                while true {
                    paths.append((path.path, try Self.pathIdentity(path.path)))
                    if path.path == "/" { break }
                    path.deleteLastPathComponent()
                }
            }
            self.handle = handle
            self.identity = identity
            self.sessionID = sessionID
            self.paths = paths
        } catch { throw error }
        try validate()
    }

    func validate() throws {
        var attributes = stat()
        guard fstat(descriptor, &attributes) == 0, Identity(attributes) == identity else {
            throw TranscriptFailure.staleSession
        }
        for (path, expected) in paths {
            guard (try? Self.pathIdentity(path)) == expected else { throw TranscriptFailure.staleSession }
        }
        if let data = try read("session.json") {
            let metadata = try JSONDecoder().decode(SessionManifest.self, from: data)
            try metadata.validate()
            guard metadata.id == sessionID else { throw TranscriptFailure.staleSession }
        }
        if let data = try read("manifest.json") {
            let metadata = try JSONDecoder().decode(RecordingManifest.self, from: data)
            try metadata.validate()
            guard metadata.id == sessionID else { throw TranscriptFailure.staleSession }
        }
        if let data = try read("transcript.json") {
            struct Header: Decodable { let sessionID: UUID }
            guard try JSONDecoder().decode(Header.self, from: data).sessionID == sessionID else {
                throw TranscriptFailure.staleSession
            }
        }
    }

    func readTranscript() throws -> Data? {
        try validate()
        let data = try read("transcript.json")
        try validate()
        return data
    }

    func commit(_ data: Data) throws {
        guard data.count <= TranscriptLimits.maximumFileBytes else {
            throw TranscriptFailure.capacityExceeded
        }
        try validate()
        let temporary = ".transcript-\(UUID().uuidString).tmp"
        let output = openat(
            descriptor, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard output >= 0 else { throw Self.posixError() }
        defer {
            close(output)
            _ = unlinkat(descriptor, temporary, 0)
        }
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(output, base.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw Self.posixError() }
                offset += count
            }
        }
        guard fsync(output) == 0 else { throw Self.posixError() }
        try validate()
        guard renameat(descriptor, temporary, descriptor, "transcript.json") == 0 else {
            throw Self.posixError()
        }
        try validate()
    }

    private func read(_ name: String) throws -> Data? {
        // Open special metadata without waiting for a peer, then reject it before any read.
        let input = openat(descriptor, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if input < 0, errno == ENOENT { return nil }
        guard input >= 0 else { throw Self.posixError() }
        defer { close(input) }
        var attributes = stat()
        guard fstat(input, &attributes) == 0 else { throw Self.posixError() }
        guard attributes.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), attributes.st_size >= 0,
            attributes.st_size <= TranscriptLimits.maximumFileBytes
        else { throw TranscriptFailure.invalidPath }
        var data = Data(count: Int(attributes.st_size))
        try data.withUnsafeMutableBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.read(input, base.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw TranscriptFailure.invalidEntry }
                offset += count
            }
        }
        return data
    }

    private static func pathIdentity(_ path: String) throws -> Identity {
        var attributes = stat()
        guard lstat(path, &attributes) == 0 else { throw posixError() }
        return Identity(attributes)
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
