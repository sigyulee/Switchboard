import BridgeCore
import Foundation
import RecorderKit

struct SessionStorePathChecks {
    func destinationThroughAncestorAliasCannotEnterDraft() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(draftRoot: root.appendingPathComponent("drafts"))
        var state = try SessionState(name: "Contained draft")
        try state.start(at: 0)
        let draft = try SessionManifest(state: state)
        let source = try store.createDraft(draft)
        let child = source.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)
        let sentinel = Data("source payload remains intact".utf8)
        try sentinel.write(to: source.appendingPathComponent("source.caf"))
        let before = try Data(contentsOf: source.appendingPathComponent("session.json"))
        let alias = root.appendingPathComponent("source-alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: source)
        let destination = alias.appendingPathComponent("Contents/saved.switchboard", isDirectory: true)
        try state.end(at: 48_000)
        let complete = try SessionManifest(state: state, createdAt: draft.createdAt, isDraft: false)

        var rejectedBeforeCopy = false
        do {
            _ = try store.publishClosedDraft(at: source, to: destination, manifest: complete)
        } catch SessionStoreError.invalidPackage {
            rejectedBeforeCopy = true
        }
        try expect(rejectedBeforeCopy)
        try expect(FileManager.default.contentsOfDirectory(atPath: child.path).isEmpty)
        try expect(Data(contentsOf: source.appendingPathComponent("session.json")) == before)
        try expect(Data(contentsOf: source.appendingPathComponent("source.caf")) == sentinel)
        try expect(store.load(at: source) == draft)
        try expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    func ancestorAliasesPreserveDraftOwnershipAndPublication() throws {
        // NSTemporaryDirectory commonly uses /var, while its canonical ancestor
        // is /private/var. Both that OS alias and explicit directory aliases work.
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let physical = root.appendingPathComponent("physical", isDirectory: true)
        let saved = physical.appendingPathComponent("saved", isDirectory: true)
        try FileManager.default.createDirectory(at: saved, withIntermediateDirectories: true)
        let alias = root.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: physical)
        let draftRoot = alias.appendingPathComponent("drafts", isDirectory: true)
        let store = SessionStore(draftRoot: draftRoot)
        var state = try SessionState(name: "Canonical ownership")
        try state.start(at: 0)
        let draft = try SessionManifest(state: state)
        let source = try store.createDraft(draft)
        let sourceAlias = draftRoot.appendingPathComponent(source.lastPathComponent, isDirectory: true)
        try state.advance(to: 48_000)
        let updated = try SessionManifest(state: state, createdAt: draft.createdAt)
        try store.update(updated, at: sourceAlias)
        try expect(store.load(at: source) == updated)
        try state.end(at: 96_000)
        let complete = try SessionManifest(state: state, createdAt: draft.createdAt, isDraft: false)
        let destination = alias.appendingPathComponent("saved/session.switchboard", isDirectory: true)
        let result = try store.publishClosedDraft(at: sourceAlias, to: destination, manifest: complete)
        try expect(result.retainedDraft == nil)
        try expect(store.load(at: saved.appendingPathComponent("session.switchboard")) == complete)
        try expect(store.load(at: result.directory) == complete)
        try expect(!FileManager.default.fileExists(atPath: source.path))
    }

    func canonicalAncestorsDoNotFollowFinalPackageSymlink() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(draftRoot: root.appendingPathComponent("drafts"))
        let draft = try SessionManifest(state: SessionState(name: "Final component"))
        let source = try store.createDraft(draft)
        let physical = root.appendingPathComponent("physical", isDirectory: true)
        try FileManager.default.createDirectory(at: physical, withIntermediateDirectories: false)
        let alias = root.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: physical)
        let finalLink = physical.appendingPathComponent("link.switchboard")
        try FileManager.default.createSymbolicLink(at: finalLink, withDestinationURL: source)
        var rejected = false
        do {
            _ = try store.load(at: alias.appendingPathComponent("link.switchboard"))
        } catch SessionStoreError.invalidPackage {
            rejected = true
        }
        try expect(rejected)
        try expect(store.load(at: source) == draft)
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "session-path-check-\(UUID().uuidString)")
    }
}
