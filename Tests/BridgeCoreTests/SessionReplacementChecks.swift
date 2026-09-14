import BridgeCore
import Foundation
import RecorderKit
import Synchronization

struct SessionReplacementChecks {
    func replacementRequiresExplicitAuthorization() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = try fixture(root, name: "Original")
        let destination = root.appendingPathComponent("Conversation.switchboard")
        _ = try old.store.publishClosedDraft(at: old.source, to: destination, manifest: old.complete)
        let new = try fixture(root, name: "New session")
        let sourceBytes = try Data(contentsOf: new.source.appendingPathComponent("session.json"))
        try expectThrows {
            _ = try new.store.publishClosedDraft(at: new.source, to: destination, manifest: new.complete)
        }
        try expect(new.store.load(at: destination) == old.complete)
        try expect(payload(at: destination) == old.payload)
        try expect(Data(contentsOf: new.source.appendingPathComponent("session.json")) == sourceBytes)
    }

    func authorizedSwapPublishesNewAndRetainsTheOriginalPackage() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = try fixture(root, name: "Original")
        let destination = root.appendingPathComponent("Named conversation.switchboard")
        _ = try old.store.publishClosedDraft(at: old.source, to: destination, manifest: old.complete)
        let originalInode = try inode(destination)
        let authorization = try SessionStore.replacementAuthorization(for: destination)
        let new = try fixture(root, name: "Replacement")
        let result = try new.store.publishClosedDraft(
            at: new.source, to: destination, manifest: new.complete, replacement: authorization)
        guard let backup = result.retainedReplacementBackup else {
            throw CheckFailure(description: "replacement discarded its original")
        }
        try expect(result.retainedDraft == nil && !FileManager.default.fileExists(atPath: new.source.path))
        try expect(new.store.load(at: result.directory) == new.complete)
        try expect(payload(at: destination) == new.payload)
        try expect(new.store.load(at: backup) == old.complete && payload(at: backup) == old.payload)
        try expect(inode(backup) == originalInode)
        try expect(
            backup.lastPathComponent == destination.lastPathComponent && backup.pathExtension == "switchboard"
        )
        let mode =
            try FileManager.default.attributesOfItem(atPath: backup.deletingLastPathComponent().path)[
                .posixPermissions] as! Int
        try expect(mode & 0o777 == 0o700)
    }

    func changedDestinationIdentityRejectsTheStaleAuthorization() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = try fixture(root, name: "Original")
        let destination = root.appendingPathComponent("Conversation.switchboard")
        _ = try old.store.publishClosedDraft(at: old.source, to: destination, manifest: old.complete)
        let authorization = try SessionStore.replacementAuthorization(for: destination)
        let moved = root.appendingPathComponent("Moved original.switchboard")
        try FileManager.default.moveItem(at: destination, to: moved)
        let concurrent = try fixture(root, name: "Another writer")
        _ = try concurrent.store.publishClosedDraft(
            at: concurrent.source, to: destination, manifest: concurrent.complete)
        let new = try fixture(root, name: "Pending replacement")
        try expectThrows {
            _ = try new.store.publishClosedDraft(
                at: new.source, to: destination, manifest: new.complete, replacement: authorization)
        }
        try expect(
            new.store.load(at: destination) == concurrent.complete
                && payload(at: destination) == concurrent.payload)
        try expect(new.store.load(at: moved) == old.complete && payload(at: moved) == old.payload)
        try expect(new.store.load(at: new.source) == new.draft)
        try expectThrows {
            _ = try new.store.publishClosedDraft(
                at: new.source, to: moved, manifest: new.complete, replacement: authorization)
        }
    }

    func destinationChangedAfterCopyIsRejectedAtTheCoordinatedCommit() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        for replacing in [false, true] {
            let folder = root.appendingPathComponent(replacing ? "replace" : "new")
            let old = try fixture(folder, name: "Original")
            let destination = folder.appendingPathComponent("Conversation.switchboard")
            let movedOriginal = folder.appendingPathComponent("Moved original.switchboard")
            var authorization: SessionReplacementAuthorization?
            if replacing {
                _ = try old.store.publishClosedDraft(at: old.source, to: destination, manifest: old.complete)
                authorization = try SessionStore.replacementAuthorization(for: destination)
            }
            let incoming = try fixture(folder, name: "Concurrent arrival")
            let incomingLocation = folder.appendingPathComponent("Incoming.switchboard")
            _ = try incoming.store.publishClosedDraft(
                at: incoming.source, to: incomingLocation, manifest: incoming.complete)
            let new = try fixture(folder, name: "Pending save")
            let presenter = CommitRacePresenter(url: destination) {
                if replacing { try FileManager.default.moveItem(at: destination, to: movedOriginal) }
                try FileManager.default.moveItem(at: incomingLocation, to: destination)
            }
            NSFileCoordinator.addFilePresenter(presenter)
            defer { NSFileCoordinator.removeFilePresenter(presenter) }
            try expectThrows {
                _ = try new.store.publishClosedDraft(
                    at: new.source, to: destination, manifest: new.complete, replacement: authorization)
            }
            try expect(presenter.invoked && presenter.failure == nil)
            try expect(
                new.store.load(at: destination) == incoming.complete
                    && payload(at: destination) == incoming.payload)
            try expect(new.store.load(at: new.source) == new.draft && payload(at: new.source) == new.payload)
            if replacing {
                try expect(
                    new.store.load(at: movedOriginal) == old.complete
                        && payload(at: movedOriginal) == old.payload)
            }
        }
    }

    func changedMetadataAndSymlinkTargetsCannotBeAuthorizedAway() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = try fixture(root, name: "Original")
        let destination = root.appendingPathComponent("Conversation.switchboard")
        _ = try old.store.publishClosedDraft(at: old.source, to: destination, manifest: old.complete)
        let authorization = try SessionStore.replacementAuthorization(for: destination)
        let different = try fixture(root, name: "Changed metadata")
        try JSONEncoder().encode(different.complete).write(
            to: destination.appendingPathComponent("session.json"), options: .atomic)
        let new = try fixture(root, name: "Replacement")
        try expectThrows {
            _ = try new.store.publishClosedDraft(
                at: new.source, to: destination, manifest: new.complete, replacement: authorization)
        }
        try expect(new.store.load(at: destination) == different.complete)
        try expect(new.store.load(at: new.source) == new.draft)
        let link = root.appendingPathComponent("Linked.switchboard")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: destination)
        try expectThrows { _ = try SessionStore.replacementAuthorization(for: link) }
        let arbitrary = root.appendingPathComponent("Unrelated.switchboard")
        try FileManager.default.createDirectory(at: arbitrary, withIntermediateDirectories: true)
        try Data("unrelated user data".utf8).write(to: arbitrary.appendingPathComponent("keep.txt"))
        try expectThrows { _ = try SessionStore.replacementAuthorization(for: arbitrary) }
        try expect(
            Data(contentsOf: arbitrary.appendingPathComponent("keep.txt")) == Data("unrelated user data".utf8)
        )
    }

    func invalidCopyPayloadPreservesTheDraftAndExistingPackage() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = try fixture(root, name: "Original")
        let destination = root.appendingPathComponent("Conversation.switchboard")
        _ = try old.store.publishClosedDraft(at: old.source, to: destination, manifest: old.complete)
        let authorization = try SessionStore.replacementAuthorization(for: destination)
        let new = try fixture(root, name: "Replacement")
        let external = root.appendingPathComponent("external.txt")
        try Data("external bytes".utf8).write(to: external)
        try FileManager.default.createSymbolicLink(
            at: new.source.appendingPathComponent("invalid-payload"), withDestinationURL: external)
        try expectThrows {
            _ = try new.store.publishClosedDraft(
                at: new.source, to: destination, manifest: new.complete, replacement: authorization)
        }
        try expect(new.store.load(at: destination) == old.complete && payload(at: destination) == old.payload)
        try expect(new.store.load(at: new.source) == new.draft && payload(at: new.source) == new.payload)
        try expect(Data(contentsOf: external) == Data("external bytes".utf8))
        try FileManager.default.removeItem(at: new.source.appendingPathComponent("invalid-payload"))
        let unreadable = new.source.appendingPathComponent("payload.dat")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: unreadable.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: unreadable.path)
        }
        try expect(!FileManager.default.isReadableFile(atPath: unreadable.path))
        // The regular-file preflight succeeds; the real recursive copy must fail on this payload.
        try expectThrows {
            _ = try new.store.publishClosedDraft(
                at: new.source, to: destination, manifest: new.complete, replacement: authorization)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: unreadable.path)
        try expect(new.store.load(at: destination) == old.complete && payload(at: destination) == old.payload)
        try expect(new.store.load(at: new.source) == new.draft && payload(at: new.source) == new.payload)
        try expect(
            !FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".session-") }
        )
    }

    func failedBackupRelocationCannotRollBackASuccessfulSave() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = try fixture(root, name: "Original")
        let destination = root.appendingPathComponent("Conversation.switchboard")
        _ = try old.store.publishClosedDraft(at: old.source, to: destination, manifest: old.complete)
        let authorization = try SessionStore.replacementAuthorization(for: destination)
        let blocker = root.appendingPathComponent("not-a-backup-directory")
        try Data("keep this file".utf8).write(to: blocker)
        let new = try fixture(root, name: "Replacement")
        let result = try new.store.publishClosedDraft(
            at: new.source, to: destination, manifest: new.complete, replacement: authorization,
            replacementBackupDirectory: blocker)
        guard let backup = result.retainedReplacementBackup else {
            throw CheckFailure(description: "failed backup move lost the original")
        }
        try expect(new.store.load(at: destination) == new.complete && payload(at: destination) == new.payload)
        try expect(new.store.load(at: backup) == old.complete && payload(at: backup) == old.payload)
        try expect(result.retainedDraft == nil && !FileManager.default.fileExists(atPath: new.source.path))
        try expect(Data(contentsOf: blocker) == Data("keep this file".utf8))
    }

    func replacementBackupCanMoveToAnExplicitRetentionDirectory() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = try fixture(root, name: "Original")
        let destination = root.appendingPathComponent("Conversation.switchboard")
        _ = try old.store.publishClosedDraft(at: old.source, to: destination, manifest: old.complete)
        let authorization = try SessionStore.replacementAuthorization(for: destination)
        let backups = root.appendingPathComponent("Backups", isDirectory: true)
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        let new = try fixture(root, name: "Replacement")
        let result = try new.store.publishClosedDraft(
            at: new.source, to: destination, manifest: new.complete, replacement: authorization,
            replacementBackupDirectory: backups)
        guard let backup = result.retainedReplacementBackup else {
            throw CheckFailure(description: "backup relocation lost its result")
        }
        try expect(
            backup.deletingLastPathComponent().deletingLastPathComponent().resolvingSymlinksInPath().path
                == backups.resolvingSymlinksInPath().path)
        try expect(new.store.load(at: backup) == old.complete && payload(at: backup) == old.payload)
        try expect(new.store.load(at: destination) == new.complete && result.retainedDraft == nil)
    }

    private struct Fixture: Sendable {
        let store: SessionStore
        let source: URL
        let draft: SessionManifest
        let complete: SessionManifest
        let payload: Data
    }

    private func fixture(_ root: URL, name: String) throws -> Fixture {
        let store = SessionStore(draftRoot: root.appendingPathComponent("drafts-\(UUID().uuidString)"))
        var state = try SessionState(name: name)
        try state.start(at: 0)
        let draft = try SessionManifest(state: state)
        let source = try store.createDraft(draft)
        let payload = Data("\(name) payload".utf8)
        try payload.write(to: source.appendingPathComponent("payload.dat"))
        try state.end(at: 48_000)
        let complete = try SessionManifest(state: state, createdAt: draft.createdAt, isDraft: false)
        return Fixture(store: store, source: source, draft: draft, complete: complete, payload: payload)
    }

    private func payload(at directory: URL) throws -> Data {
        try Data(contentsOf: directory.appendingPathComponent("payload.dat"))
    }

    private func inode(_ directory: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        return (attributes[.systemFileNumber] as! NSNumber).uint64Value
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "session-replacement-\(UUID().uuidString)")
    }
}

/// A real file presenter introduces a deterministic competing filesystem change after staging,
/// when the store requests its coordinated write. Publication itself is never mocked.
private final class CommitRacePresenter: NSObject, NSFilePresenter, @unchecked Sendable {
    private struct State {
        var invoked = false
        var failure: (any Error)?
    }
    private let state = Mutex(State())
    private let mutation: @Sendable () throws -> Void
    let presentedItemURL: URL?
    let presentedItemOperationQueue: OperationQueue
    var invoked: Bool { state.withLock { $0.invoked } }
    var failure: (any Error)? { state.withLock { $0.failure } }

    init(url: URL, mutation: @escaping @Sendable () throws -> Void) {
        presentedItemURL = url
        self.mutation = mutation
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        presentedItemOperationQueue = queue
        super.init()
    }

    fileprivate func relinquishPresentedItem(
        toWriter writer: @escaping @Sendable ((@Sendable () -> Void)?) -> Void
    ) {
        applyMutation()
        writer(nil)
    }

    fileprivate func accommodatePresentedItemDeletion(
        completionHandler: @escaping @Sendable ((any Error)?) -> Void
    ) {
        applyMutation()
        completionHandler(nil)
    }

    private func applyMutation() {
        let shouldRun = state.withLock { state in
            guard !state.invoked else { return false }
            state.invoked = true
            return true
        }
        guard shouldRun else { return }
        do { try mutation() } catch { state.withLock { $0.failure = error } }
    }
}
