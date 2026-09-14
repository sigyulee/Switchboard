import BridgeCore
import Darwin
import Foundation

public enum SessionStoreError: Error, Equatable, LocalizedError, Sendable {
    case invalidPackage, invalidDraft, invalidMetadata, identityMismatch, staleMetadata, destinationExists
    case replacementChanged

    public var errorDescription: String? {
        switch self {
        case .invalidPackage: "The session package path or contents are invalid."
        case .invalidDraft: "This is not a draft owned by this session store."
        case .invalidMetadata: "The session metadata is missing, damaged, or too large."
        case .identityMismatch: "The session metadata belongs to another session."
        case .staleMetadata: "Newer session metadata is already saved."
        case .destinationExists: "A file already exists at the selected session destination."
        case .replacementChanged: "The session at the save destination changed. Choose the destination again."
        }
    }
}

public struct StoredSession: Equatable, Sendable {
    public let directory: URL
    public let manifest: SessionManifest
}

public struct SessionPublication: Equatable, Sendable {
    public let directory: URL
    /// Publication succeeded, but this old draft still needs cleanup if non-nil.
    public let retainedDraft: URL?
    /// The replaced package remains recoverable here. The caller may move this exact package to Trash.
    public let retainedReplacementBackup: URL?
}

/// An in-memory identity snapshot for one explicitly approved replacement destination.
/// It is not persisted in session metadata and cannot authorize a different or changed package.
public struct SessionReplacementAuthorization: Sendable {
    public let destination: URL
    public let sessionID: UUID
    fileprivate let device: UInt64
    fileprivate let inode: UInt64
    fileprivate let metadata: SessionManifest
}

/// A closed package snapshot, retained while the user chooses an export destination.
public struct SessionExportSource: Sendable {
    public let directory: URL
    public var fileExtension: String { SessionManifest.packageExtension }
    public var title: String { recording.title }
    fileprivate let recording: RecordingManifest
    fileprivate let session: SessionManifest?
    fileprivate let exportedSession: SessionManifest
    fileprivate let contents: [String: SessionExportEntry]
}

private struct SessionExportEntry: Equatable, Sendable {
    let directory: Bool
    let device: UInt64
    let inode: UInt64
    let bytes: UInt64
    let modified: Date
}

/// Synchronous filesystem operations. Call on one owned file queue, never a realtime callback.
/// Close and await every audio/transcript writer before publishing; this store does not move live writers.
public struct SessionStore: Sendable {
    public let draftRoot: URL
    private static let maximumMetadataBytes = 4 * 1_024 * 1_024

    public init(draftRoot: URL) { self.draftRoot = draftRoot }

    /// Capture only after the user confirms Replace. All writers of this target must also be joined.
    public static func replacementAuthorization(for destination: URL) throws
        -> SessionReplacementAuthorization
    {
        let destination = try packagePath(destination)
        let before = try identity(destination)
        let metadata = try Self(draftRoot: destination.deletingLastPathComponent()).load(at: destination)
        try requireRegularTree(destination)
        guard try identity(destination) == before else { throw SessionStoreError.replacementChanged }
        return SessionReplacementAuthorization(
            destination: destination, sessionID: metadata.id, device: before.device, inode: before.inode,
            metadata: metadata)
    }

    public func createDraft(_ manifest: SessionManifest) throws -> URL {
        try manifest.validate()
        guard manifest.isDraft else { throw SessionStoreError.invalidDraft }
        let root = try Self.normalizedPath(draftRoot)
        if !FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.createDirectory(
                at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try Self.requireDirectory(root)
        let directory = root.appendingPathComponent(
            manifest.id.uuidString + "." + SessionManifest.packageExtension, isDirectory: true)
        guard !Self.exists(directory) else { throw SessionStoreError.destinationExists }
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        // A failed metadata write leaves the private directory available for inspection.
        try Self.write(manifest, at: directory)
        return directory
    }

    public func update(_ manifest: SessionManifest, at directory: URL) throws {
        try manifest.validate()
        let directory = try Self.packagePath(directory)
        let current = try load(at: directory)
        try Self.requireSuccessor(manifest, of: current)
        try Self.write(manifest, at: directory)
    }

    public func load(at directory: URL) throws -> SessionManifest {
        try Self.metadata(in: Self.packagePath(directory))
    }

    /// Join all package writers before preparing an export, and keep them stopped until it finishes.
    /// Legacy input is exported as a session package while its original files remain unchanged.
    public static func prepareExport(of item: RecordingItem) throws -> SessionExportSource {
        try Task.checkCancellation()
        let directory = try normalizedPath(item.directory)
        let fileExtension = directory.pathExtension.lowercased()
        guard [SessionManifest.packageExtension, "mihrecording"].contains(fileExtension) else {
            throw SessionStoreError.invalidPackage
        }
        let contents = try exportTree(directory)
        guard let manifestFile = contents["manifest.json"], !manifestFile.directory,
            manifestFile.bytes > 0, manifestFile.bytes <= UInt64(maximumMetadataBytes)
        else { throw SessionStoreError.invalidMetadata }
        let current = try RecordingLibrary.item(at: directory)
        guard current.id == item.id, current.manifest.createdAt == item.manifest.createdAt else {
            throw SessionStoreError.identityMismatch
        }
        guard current.manifest.status != .recording, current.manifest.status != .finalizing else {
            throw SessionManifestError.unfinishedSession
        }
        let session: SessionManifest?
        if directory.pathExtension.lowercased() == SessionManifest.packageExtension
            || contents[SessionManifest.filename] != nil
        {
            session = try metadata(in: directory)
            guard session?.isDraft == false else { throw SessionStoreError.invalidDraft }
        } else {
            session = nil
        }
        let exportedSession =
            try session
            ?? SessionManifest(
                state: SessionState(archiving: current.manifest), createdAt: current.manifest.createdAt,
                isDraft: false)
        let source = SessionExportSource(
            directory: directory, recording: current.manifest, session: session,
            exportedSession: exportedSession, contents: contents)
        try requireUnchangedExport(source)
        return source
    }

    /// Save-panel validation and publication share the same path and collision policy.
    /// Existing files are always refused; exporting cannot replace the original or another package.
    public static func validateExportDestination(_ destination: URL, for source: SessionExportSource)
        throws -> URL
    {
        let destination = try normalizedPath(destination)
        guard destination.pathExtension.lowercased() == source.fileExtension,
            let root = source.contents[""]
        else { throw SessionStoreError.invalidPackage }
        let parent = destination.deletingLastPathComponent()
        try requireDirectory(parent)
        try requireOutsideSource(parent, sourceIdentity: FileIdentity(device: root.device, inode: root.inode))
        guard !exists(destination) else { throw SessionStoreError.destinationExists }
        return destination
    }

    /// Copies existing bytes on a file worker, then atomically publishes a complete package.
    /// The source is never moved, rewritten, or removed. Cancellation before commit discards only staging.
    public static func exportCopy(of source: SessionExportSource, to destination: URL) throws -> URL {
        try Task.checkCancellation()
        try requireUnchangedExport(source)
        let destination = try validateExportDestination(destination, for: source)
        let parent = destination.deletingLastPathComponent()
        let parentIdentity = try identity(parent)
        let container = parent.appendingPathComponent(".session-export-\(UUID().uuidString).staging")
        try FileManager.default.createDirectory(
            at: container, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let containerIdentity = try identity(container)
        defer {
            // Never clean an unrelated directory that replaced our staging container.
            if (try? identity(container)) == containerIdentity {
                try? FileManager.default.removeItem(at: container)
            }
        }
        let staging = container.appendingPathComponent(destination.lastPathComponent, isDirectory: true)
        try Task.checkCancellation()
        try FileManager.default.copyItem(at: source.directory, to: staging)
        try Task.checkCancellation()
        let copied = try exportTree(staging)
        guard copied.count == source.contents.count,
            copied.allSatisfy({ path, entry in
                guard let original = source.contents[path] else { return false }
                return entry.directory == original.directory && entry.bytes == original.bytes
            }),
            try RecordingManifest.load(from: staging) == source.recording,
            try source.session == nil || metadata(in: staging) == source.session
        else { throw SessionStoreError.invalidPackage }
        if source.session == nil { try write(source.exportedSession, at: staging) }
        guard try RecordingLibrary.item(at: staging).manifest == source.recording,
            try metadata(in: staging) == source.exportedSession
        else { throw SessionStoreError.invalidPackage }
        let exportedContents = try exportTree(staging)

        try coordinatePublication(at: destination) { coordinated in
            try Task.checkCancellation()
            guard try normalizedPath(coordinated) == destination,
                try identity(parent) == parentIdentity,
                try identity(container) == containerIdentity,
                try exportTree(staging) == exportedContents
            else { throw SessionStoreError.replacementChanged }
            try requireUnchangedExport(source)
            _ = try validateExportDestination(destination, for: source)
            try Task.checkCancellation()
            try rename(staging, to: destination, flags: UInt32(RENAME_EXCL))
        }
        return destination
    }

    private static func requireUnchangedExport(_ source: SessionExportSource) throws {
        guard try exportTree(source.directory) == source.contents,
            try RecordingLibrary.item(at: source.directory).manifest == source.recording,
            try source.session == nil || metadata(in: source.directory) == source.session
        else { throw SessionStoreError.staleMetadata }
    }

    private static func exportTree(_ directory: URL) throws -> [String: SessionExportEntry] {
        var pending = [(directory, "")]
        var contents: [String: SessionExportEntry] = [:]
        while let (url, path) = pending.popLast() {
            try Task.checkCancellation()
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let type = attributes[.type] as? FileAttributeType
            guard type == .typeDirectory || type == .typeRegular,
                let device = attributes[.systemNumber] as? NSNumber,
                let inode = attributes[.systemFileNumber] as? NSNumber,
                let bytes = attributes[.size] as? NSNumber, bytes.int64Value >= 0,
                let modified = attributes[.modificationDate] as? Date
            else { throw SessionStoreError.invalidPackage }
            contents[path] = SessionExportEntry(
                directory: type == .typeDirectory, device: device.uint64Value, inode: inode.uint64Value,
                bytes: type == .typeDirectory ? 0 : bytes.uint64Value, modified: modified)
            if type == .typeDirectory {
                for child in try FileManager.default.contentsOfDirectory(
                    at: url, includingPropertiesForKeys: nil)
                {
                    let childPath =
                        path.isEmpty ? child.lastPathComponent : path + "/" + child.lastPathComponent
                    pending.append((child, childPath))
                }
            }
        }
        guard contents[""]?.directory == true else { throw SessionStoreError.invalidPackage }
        return contents
    }

    /// Read session metadata independently of a file's extension, including renamed archives.
    public static func metadata(in directory: URL) throws -> SessionManifest {
        let directory = try normalizedPath(directory)
        try Self.requireDirectory(directory)
        let metadata = directory.appendingPathComponent(SessionManifest.filename)
        let attributes = try FileManager.default.attributesOfItem(atPath: metadata.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
            let size = attributes[.size] as? NSNumber, size.int64Value > 0,
            size.int64Value <= Self.maximumMetadataBytes
        else { throw SessionStoreError.invalidMetadata }
        let data = try Data(contentsOf: metadata)
        guard data.count <= Self.maximumMetadataBytes else { throw SessionStoreError.invalidMetadata }
        return try JSONDecoder().decode(SessionManifest.self, from: data)
    }

    public func drafts() throws -> [StoredSession] {
        try packages(in: draftRoot).filter { $0.manifest.isDraft }
    }

    /// Reads immediate package metadata only. A corrupt candidate is reported, not deleted or processed.
    public func packages(in root: URL) throws -> [StoredSession] {
        let root = try Self.normalizedPath(root)
        guard Self.exists(root) else { return [] }
        try Self.requireDirectory(root)
        let candidates = try FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        ).filter {
            $0.pathExtension.lowercased() == SessionManifest.packageExtension
        }
        return try candidates.map { directory in
            StoredSession(directory: try Self.packagePath(directory), manifest: try load(at: directory))
        }.sorted {
            if $0.manifest.createdAt == $1.manifest.createdAt { return $0.directory.path < $1.directory.path }
            return $0.manifest.createdAt > $1.manifest.createdAt
        }
    }

    /// Publishes after every source and replacement-target writer joins. Existing destinations are refused by default.
    /// An authorized replacement swaps atomically and retains the old package; cleanup never deletes that old data.
    /// The optional backup directory is a best-effort, same-volume relocation after publication, not a save requirement.
    public func publishClosedDraft(
        at directory: URL, to destination: URL, manifest: SessionManifest,
        replacement: SessionReplacementAuthorization? = nil, replacementBackupDirectory: URL? = nil
    ) throws -> SessionPublication {
        try manifest.validate()
        guard !manifest.isDraft else { throw SessionStoreError.invalidDraft }
        let root = try Self.normalizedPath(draftRoot)
        let source = try Self.packagePath(directory)
        guard try Self.normalizedPath(source.deletingLastPathComponent()) == root,
            source.lastPathComponent == manifest.id.uuidString + "." + SessionManifest.packageExtension
        else { throw SessionStoreError.invalidDraft }
        let current = try load(at: source)
        guard current.isDraft else { throw SessionStoreError.invalidDraft }
        try Self.requireSuccessor(manifest, of: current)
        let sourceIdentity = try Self.identity(source)
        let destination = try Self.packagePath(destination)
        let parent = destination.deletingLastPathComponent()
        try Self.requireDirectory(parent)
        let parentIdentity = try Self.identity(parent)
        if let replacement {
            let targetIdentity = try Self.requireReplacement(replacement, at: destination)
            guard targetIdentity != sourceIdentity else { throw SessionStoreError.invalidPackage }
            try Self.requireOutsideSource(source.deletingLastPathComponent(), sourceIdentity: targetIdentity)
        } else if Self.exists(destination) {
            throw SessionStoreError.destinationExists
        }
        try Self.requireOutsideSource(parent, sourceIdentity: sourceIdentity)
        try Self.requireRegularTree(source)

        let stagingContainer = parent.appendingPathComponent(
            ".session-\(UUID().uuidString).staging", isDirectory: true)
        var containsReplacedPackage = false
        defer {
            if !containsReplacedPackage { try? FileManager.default.removeItem(at: stagingContainer) }
        }
        try FileManager.default.createDirectory(
            at: stagingContainer, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let staging = stagingContainer.appendingPathComponent(
            destination.lastPathComponent, isDirectory: true)
        try FileManager.default.copyItem(at: source, to: staging)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: staging.path)
        try Self.write(manifest, at: staging)
        try Self.requireRegularTree(staging)
        guard try load(at: staging) == manifest else { throw SessionStoreError.invalidMetadata }

        try Self.coordinatePublication(at: destination) { coordinated in
            guard try Self.packagePath(coordinated) == destination,
                try Self.identity(parent) == parentIdentity
            else { throw SessionStoreError.replacementChanged }
            if let replacement {
                _ = try Self.requireReplacement(replacement, at: destination)
                try Self.rename(staging, to: destination, flags: UInt32(RENAME_SWAP))
                // From this point onward staging contains user data, never disposable staging content.
                containsReplacedPackage = true
            } else {
                // The kernel refuses a destination that arrives even after the preflight check.
                try Self.rename(staging, to: destination, flags: UInt32(RENAME_EXCL))
            }
        }

        var replacementBackup = containsReplacedPackage ? staging : nil
        if containsReplacedPackage, let replacementBackupDirectory {
            do {
                let backupRoot = try Self.normalizedPath(replacementBackupDirectory)
                try Self.requireDirectory(backupRoot)
                // A retained backup cannot be placed inside a package that this transaction cleans or replaces.
                for protected in [sourceIdentity, try Self.identity(destination), try Self.identity(staging)]
                {
                    try Self.requireOutsideSource(backupRoot, sourceIdentity: protected)
                }
                let relocated = backupRoot.appendingPathComponent(
                    stagingContainer.lastPathComponent, isDirectory: true)
                try Self.rename(stagingContainer, to: relocated, flags: UInt32(RENAME_EXCL))
                replacementBackup = relocated.appendingPathComponent(
                    destination.lastPathComponent, isDirectory: true)
            } catch {
                // Publication is already committed. Return the original recoverable backup location.
            }
        }

        // Never turn a completed save into a retryable error or remove a replaced/changed draft.
        var retainedDraft: URL? = source
        if (try? Self.identity(source)) == sourceIdentity, (try? load(at: source)) == current {
            do {
                try FileManager.default.removeItem(at: source)
                retainedDraft = nil
            } catch {}
        }
        return SessionPublication(
            directory: destination, retainedDraft: retainedDraft, retainedReplacementBackup: replacementBackup
        )
    }

    private static func requireReplacement(
        _ authorization: SessionReplacementAuthorization, at destination: URL
    ) throws -> FileIdentity {
        guard authorization.destination == destination,
            let current = try? identity(destination), current.device == authorization.device,
            current.inode == authorization.inode,
            let metadata = try? Self(draftRoot: destination.deletingLastPathComponent()).load(
                at: destination),
            metadata.id == authorization.sessionID, metadata == authorization.metadata
        else { throw SessionStoreError.replacementChanged }
        try requireRegularTree(destination)
        guard try identity(destination) == current else { throw SessionStoreError.replacementChanged }
        return current
    }

    /// Coordinates the final check and swap with file presenters and other coordinated filesystem clients.
    private static func coordinatePublication(at destination: URL, operation: (URL) throws -> Void) throws {
        var coordinationError: NSError?
        var outcome: Result<Void, any Error>?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(writingItemAt: destination, options: .forReplacing, error: &coordinationError)
        { url in
            outcome = Result { try operation(url) }
        }
        // An executed accessor's committed outcome takes precedence over a later coordination notification error.
        if let outcome {
            try outcome.get()
            return
        }
        if let coordinationError { throw coordinationError }
        throw SessionStoreError.invalidPackage
    }

    private static func rename(_ source: URL, to destination: URL, flags: UInt32) throws {
        let status = source.withUnsafeFileSystemRepresentation { sourcePath in
            destination.withUnsafeFileSystemRepresentation { destinationPath in
                guard let sourcePath, let destinationPath else {
                    errno = EINVAL
                    return Int32(-1)
                }
                return renamex_np(sourcePath, destinationPath, flags)
            }
        }
        guard status == 0 else {
            let code = errno
            if code == EEXIST { throw SessionStoreError.destinationExists }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }

    private static func requireSuccessor(_ next: SessionManifest, of current: SessionManifest) throws {
        guard next.id == current.id, next.createdAt == current.createdAt else {
            throw SessionStoreError.identityMismatch
        }
        guard next.durationFrames >= current.durationFrames,
            current.state.lifecycle != .ended || next.state.lifecycle == .ended,
            current.isDraft || !next.isDraft
        else { throw SessionStoreError.staleMetadata }
    }

    private static func write(_ manifest: SessionManifest, at directory: URL) throws {
        try manifest.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        guard data.count <= maximumMetadataBytes else { throw SessionStoreError.invalidMetadata }
        try data.write(to: directory.appendingPathComponent(SessionManifest.filename), options: .atomic)
    }

    private static func normalizedPath(_ url: URL) throws -> URL {
        guard !url.pathComponents.contains("..") else { throw SessionStoreError.invalidPackage }
        let normalized = try LibraryFolders.normalizedRoot(url)
        guard normalized.path != "/" else { return normalized }
        // Resolve ancestors, including OS aliases such as /var, but leave the
        // final package component untouched so load/creation can reject a symlink.
        let parent = try canonicalAncestor(normalized.deletingLastPathComponent())
        return parent.appendingPathComponent(normalized.lastPathComponent, isDirectory: true)
    }

    private static func canonicalAncestor(_ directory: URL) throws -> URL {
        var candidate = directory
        var missingComponents: [String] = []
        while true {
            var errorCode: Int32 = 0
            let resolved = candidate.path.withCString { path in
                let result = realpath(path, nil)
                if result == nil { errorCode = errno }
                return result
            }
            if let resolved {
                defer { free(resolved) }
                guard let path = String(validatingCString: resolved) else {
                    throw SessionStoreError.invalidPackage
                }
                var canonical = URL(fileURLWithPath: path, isDirectory: true)
                for component in missingComponents.reversed() {
                    canonical.appendPathComponent(component, isDirectory: true)
                }
                return canonical
            }
            // Draft creation may add a new directory chain. A dangling symlink
            // or a nondirectory component is not a missing directory to create.
            guard errorCode == ENOENT, !exists(candidate), candidate.path != "/" else {
                throw SessionStoreError.invalidPackage
            }
            missingComponents.append(candidate.lastPathComponent)
            candidate.deleteLastPathComponent()
        }
    }

    private static func requireOutsideSource(_ directory: URL, sourceIdentity: FileIdentity) throws {
        var ancestor = directory
        while true {
            guard try identity(ancestor) != sourceIdentity else { throw SessionStoreError.invalidPackage }
            if ancestor.path == "/" { return }
            ancestor.deleteLastPathComponent()
        }
    }

    private static func packagePath(_ url: URL) throws -> URL {
        let url = try normalizedPath(url)
        guard url.pathExtension.lowercased() == SessionManifest.packageExtension else {
            throw SessionStoreError.invalidPackage
        }
        return url
    }

    private static func exists(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    private static func requireDirectory(_ directory: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else {
            throw SessionStoreError.invalidPackage
        }
    }

    private static func requireRegularTree(_ directory: URL) throws {
        var pending = [directory]
        while let directory = pending.popLast() {
            try requireDirectory(directory)
            for child in try FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil)
            {
                let attributes = try FileManager.default.attributesOfItem(atPath: child.path)
                switch attributes[.type] as? FileAttributeType {
                case .typeDirectory: pending.append(child)
                case .typeRegular: break
                default: throw SessionStoreError.invalidPackage
                }
            }
        }
    }

    private struct FileIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
    }

    private static func identity(_ directory: URL) throws -> FileIdentity {
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
            let device = attributes[.systemNumber] as? NSNumber,
            let inode = attributes[.systemFileNumber] as? NSNumber
        else { throw SessionStoreError.invalidPackage }
        return FileIdentity(device: device.uint64Value, inode: inode.uint64Value)
    }
}
