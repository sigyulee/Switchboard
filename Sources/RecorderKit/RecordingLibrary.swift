import AVFAudio
import BridgeCore
import Darwin
import Foundation

public enum RecordingRenameError: Error, LocalizedError, Sendable {
    case rollbackFailed(backupDirectory: URL)

    public var errorDescription: String? {
        switch self {
        case .rollbackFailed(let directory):
            "The rename could not be rolled back completely. Recoverable metadata remains at \(directory.path)."
        }
    }
}

public struct RecordingItem: Equatable, Identifiable, Sendable {
    public let directory: URL
    public var manifest: RecordingManifest
    public var id: UUID { manifest.id }
    public var mixURL: URL { directory.appendingPathComponent("Conversation.m4a") }
    public init(directory: URL, manifest: RecordingManifest) {
        self.directory = directory
        self.manifest = manifest
    }
}

public enum RecordingLibrary {
    public static func items(in root: URL) throws -> [RecordingItem] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let children = try FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        return children.compactMap { try? item(at: $0) }.sorted {
            $0.manifest.createdAt > $1.manifest.createdAt
        }
    }

    public static func item(at directory: URL) throws -> RecordingItem {
        guard directory.isFileURL,
            ["mihrecording", "switchboard"].contains(directory.pathExtension.lowercased())
        else {
            throw MediaFailure.invalidPath
        }
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw MediaFailure.invalidPath
        }
        let manifest = try RecordingManifest.load(from: directory)
        if directory.pathExtension.lowercased() == SessionManifest.packageExtension
            || FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(SessionManifest.filename).path)
        {
            let session = try SessionStore.metadata(in: directory)
            guard session.id == manifest.id, session.createdAt == manifest.createdAt else {
                throw SessionStoreError.identityMismatch
            }
        }
        return RecordingItem(directory: directory, manifest: manifest)
    }

    /// Reconcile explicitly opened files without registering or scanning their parent folders.
    public static func refreshed(_ previous: [RecordingItem]) -> [RecordingItem] {
        previous.compactMap { old in
            guard let current = try? item(at: old.directory), current.id == old.id else { return nil }
            return current
        }
    }

    public static func recover(_ item: RecordingItem) throws -> RecordingItem {
        var manifest = try RecordingManifest.load(from: item.directory)
        guard manifest.status != .complete else {
            return RecordingItem(directory: item.directory, manifest: manifest)
        }
        let children = try FileManager.default.contentsOfDirectory(
            at: item.directory, includingPropertiesForKeys: [.isSymbolicLinkKey])
        let knownFilenames = Set(manifest.segments.map(\.filename))
        for url in children where url.pathExtension == "caf" {
            let filename = url.lastPathComponent
            guard !knownFilenames.contains(filename),
                (try url.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true
            else { continue }
            let components = url.deletingPathExtension().lastPathComponent.split(separator: "-")
            guard components.count == 2, let side = AudioSide(rawValue: String(components[0])),
                let start = Int64(components[1]), start >= 0,
                let file = try? AVAudioFile(forReading: url), file.length > 0
            else { continue }
            try PCM.requireRecordingFormat(file.processingFormat)
            let (end, overflow) = start.addingReportingOverflow(file.length)
            guard !overflow else { throw RecordingManifestError.invalidTimeline }
            manifest.segments.append(
                RecordingSegment(
                    side: side, filename: filename, startFrame: start, frames: file.length))
            manifest.durationFrames = max(manifest.durationFrames, end)
        }
        manifest.status = .recoverable
        if manifest.failure == nil {
            manifest.failure = MediaFailure.interrupted.localizedDescription
            manifest.failureCode = MediaFailure.interrupted.rawValue
        }
        try manifest.save(to: item.directory)
        return RecordingItem(directory: item.directory, manifest: manifest)
    }

    /// Join package writers before renaming. Only metadata changes; the package path stays fixed.
    /// All replacement bytes are staged before publication, and failed writes restore earlier swaps.
    public static func rename(_ item: RecordingItem, title: String) throws {
        try Task.checkCancellation()
        let name = try SessionState(id: item.id, name: title).name
        let directory = item.directory
        guard directory.isFileURL,
            ["mihrecording", SessionManifest.packageExtension].contains(directory.pathExtension.lowercased())
        else { throw MediaFailure.invalidPath }
        let identity = try renameIdentity(at: directory, isDirectory: true)
        var coordinationError: NSError?
        var outcome: Result<Void, any Error>?
        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: directory, options: .forMerging, error: &coordinationError
        ) { coordinated in
            outcome = Result {
                guard try renameIdentity(at: coordinated, isDirectory: true) == identity else {
                    throw SessionStoreError.replacementChanged
                }
                try renameMetadata(item, to: name, at: coordinated, identity: identity)
            }
        }
        if let outcome { return try outcome.get() }
        if let coordinationError { throw coordinationError }
        throw SessionStoreError.invalidPackage
    }

    private struct RenameIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
    }

    private struct RenameSnapshot: Equatable {
        let identity: RenameIdentity
        let bytes: Data
    }

    private static func renameMetadata(
        _ item: RecordingItem, to name: String, at directory: URL, identity: RenameIdentity
    ) throws {
        let audioURL = directory.appendingPathComponent("manifest.json")
        let audio = try renameSnapshot(at: audioURL)
        var manifest = try JSONDecoder().decode(RecordingManifest.self, from: audio.bytes)
        try manifest.validate()
        guard manifest.id == item.id, manifest.createdAt == item.manifest.createdAt else {
            throw SessionStoreError.identityMismatch
        }
        let sessionURL = directory.appendingPathComponent(SessionManifest.filename)
        let hasSession =
            directory.pathExtension.lowercased() == SessionManifest.packageExtension
            || (try? FileManager.default.attributesOfItem(atPath: sessionURL.path)) != nil
        let sessionSnapshot = try hasSession ? renameSnapshot(at: sessionURL) : nil
        var session = try sessionSnapshot.map {
            try JSONDecoder().decode(SessionManifest.self, from: $0.bytes)
        }
        if let session {
            guard session.id == manifest.id, session.createdAt == manifest.createdAt else {
                throw SessionStoreError.identityMismatch
            }
        }
        if manifest.title == name, session == nil || session?.title == name { return }
        manifest.title = name
        if let state = session?.state { session?.state = try state.renamed(to: name) }
        try manifest.validate()
        try session?.validate()
        var changes = [(url: audioURL, before: audio, bytes: try renameData(manifest))]
        if let session, let sessionSnapshot {
            changes.append((url: sessionURL, before: sessionSnapshot, bytes: try renameData(session)))
        }
        try replaceRenameMetadata(changes, in: directory, identity: identity)
    }

    private static func replaceRenameMetadata(
        _ changes: [(url: URL, before: RenameSnapshot, bytes: Data)],
        in directory: URL, identity: RenameIdentity
    ) throws {
        try Task.checkCancellation()
        let staging = directory.appendingPathComponent(".rename-\(UUID().uuidString).staging")
        try FileManager.default.createDirectory(
            at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let stagingIdentity = try renameIdentity(at: staging, isDirectory: true)
        var retainBackup = false
        defer {
            if !retainBackup, (try? renameIdentity(at: staging, isDirectory: true)) == stagingIdentity {
                try? FileManager.default.removeItem(at: staging)
            }
        }
        var replacements: [(url: URL, snapshot: RenameSnapshot)] = []
        for change in changes {
            let url = staging.appendingPathComponent(change.url.lastPathComponent)
            try change.bytes.write(to: url, options: .atomic)
            replacements.append((url, try renameSnapshot(at: url)))
        }
        var committed: [Int] = []
        do {
            for index in changes.indices {
                try Task.checkCancellation()
                guard try renameIdentity(at: directory, isDirectory: true) == identity,
                    try renameIdentity(at: staging, isDirectory: true) == stagingIdentity,
                    try renameSnapshot(at: changes[index].url) == changes[index].before,
                    try renameSnapshot(at: replacements[index].url) == replacements[index].snapshot
                else { throw SessionStoreError.staleMetadata }
                try swapRenameMetadata(changes[index].url, replacements[index].url)
                committed.append(index)
                guard try renameSnapshot(at: replacements[index].url) == changes[index].before else {
                    throw SessionStoreError.staleMetadata
                }
            }
            for index in changes.indices {
                guard try renameIdentity(at: directory, isDirectory: true) == identity,
                    try renameSnapshot(at: changes[index].url) == replacements[index].snapshot
                else { throw SessionStoreError.staleMetadata }
            }
        } catch {
            for index in committed.reversed() {
                do {
                    // Do not overwrite a competing writer or a replacement package during rollback.
                    guard try renameIdentity(at: directory, isDirectory: true) == identity,
                        try renameIdentity(at: staging, isDirectory: true) == stagingIdentity,
                        try renameSnapshot(at: changes[index].url) == replacements[index].snapshot
                    else { throw SessionStoreError.staleMetadata }
                    try swapRenameMetadata(changes[index].url, replacements[index].url)
                    guard try renameSnapshot(at: changes[index].url) == changes[index].before else {
                        throw SessionStoreError.staleMetadata
                    }
                } catch { retainBackup = true }
            }
            if retainBackup { throw RecordingRenameError.rollbackFailed(backupDirectory: staging) }
            throw error
        }
    }

    private static func renameData(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        guard data.count <= 4 * 1_024 * 1_024 else { throw SessionStoreError.invalidMetadata }
        return data
    }

    private static func renameSnapshot(at url: URL) throws -> RenameSnapshot {
        let identity = try renameIdentity(at: url, isDirectory: false)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber, size.int64Value > 0,
            size.int64Value <= 4 * 1_024 * 1_024
        else { throw SessionStoreError.invalidMetadata }
        let bytes = try Data(contentsOf: url)
        guard bytes.count <= 4 * 1_024 * 1_024,
            try renameIdentity(at: url, isDirectory: false) == identity
        else { throw SessionStoreError.staleMetadata }
        return RenameSnapshot(identity: identity, bytes: bytes)
    }

    private static func renameIdentity(at url: URL, isDirectory: Bool) throws -> RenameIdentity {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == (isDirectory ? .typeDirectory : .typeRegular),
            let device = attributes[.systemNumber] as? NSNumber,
            let inode = attributes[.systemFileNumber] as? NSNumber
        else { throw SessionStoreError.invalidPackage }
        return RenameIdentity(device: device.uint64Value, inode: inode.uint64Value)
    }

    private static func swapRenameMetadata(_ destination: URL, _ staged: URL) throws {
        let status = destination.withUnsafeFileSystemRepresentation { destinationPath in
            staged.withUnsafeFileSystemRepresentation { stagedPath in
                guard let destinationPath, let stagedPath else { return Int32(EINVAL) }
                return renamex_np(destinationPath, stagedPath, UInt32(RENAME_SWAP)) == 0 ? 0 : errno
            }
        }
        guard status == 0 else { throw POSIXError(POSIXErrorCode(rawValue: status) ?? .EIO) }
    }
}

public final class RecordingAudioReader {
    private let directory: URL
    private let segments: [RecordingSegment]
    private var currentName: String?
    private var file: AVAudioFile?
    public init(item: RecordingItem, side: AudioSide) throws {
        try item.manifest.validate()
        directory = item.directory
        segments = item.manifest.segments.filter { $0.side == side }.sorted { $0.startFrame < $1.startFrame }
    }
    public func read(at start: Int64, frames: Int) throws -> [Float] {
        try Task.checkCancellation()
        let (_, overflow) = start.addingReportingOverflow(Int64(frames))
        guard start >= 0, frames > 0, frames <= 480_000, !overflow else { throw MediaFailure.invalidBuffer }
        var result = [Float](repeating: 0, count: frames * 2)
        for segment in segments
        where segment.startFrame < start + Int64(frames) && segment.startFrame + segment.frames > start {
            try Task.checkCancellation()
            guard segment.filename == URL(fileURLWithPath: segment.filename).lastPathComponent else {
                throw MediaFailure.invalidPath
            }
            if currentName != segment.filename {
                let url = directory.appendingPathComponent(segment.filename)
                guard (try url.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else {
                    throw MediaFailure.invalidPath
                }
                file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: true)
                guard let file, file.length >= segment.frames else { throw MediaFailure.invalidBuffer }
                try PCM.requireRecordingFormat(file.processingFormat)
                currentName = segment.filename
            }
            guard let file else { throw MediaFailure.invalidBuffer }
            let begin = max(start, segment.startFrame)
            let end = min(start + Int64(frames), segment.startFrame + segment.frames)
            let count = Int(end - begin)
            file.framePosition = begin - segment.startFrame
            guard
                let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: UInt32(count))
            else { throw MediaFailure.invalidBuffer }
            // A short read can precede EOF even for canonical PCM. Only time
            // outside declared segments remains silence in the result.
            var consumed = 0
            while consumed < count {
                try Task.checkCancellation()
                try file.read(into: buffer, frameCount: UInt32(count - consumed))
                try Task.checkCancellation()
                let received = Int(buffer.frameLength)
                guard received > 0, received <= count - consumed else {
                    throw MediaFailure.invalidBuffer
                }
                let samples = try PCM.samples(buffer)
                let offset = (Int(begin - start) + consumed) * 2
                result.replaceSubrange(offset..<(offset + samples.count), with: samples)
                consumed += received
            }
        }
        try Task.checkCancellation()
        return result
    }
}
