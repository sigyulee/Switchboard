import BridgeCore
import Foundation
import RecorderKit

struct DirectRecordingChecks {
    func directRenameAndRemovalReloadWithoutRegisteringItsFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let registered = root.appendingPathComponent("library")
        let external = root.appendingPathComponent("external")
        let directory = external.appendingPathComponent("session.mihrecording")
        try FileManager.default.createDirectory(at: registered, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manifest = RecordingManifest(title: "Original", owner: .manual)
        try manifest.save(to: directory)
        let opened = try RecordingLibrary.item(at: directory)
        let folders = try LibraryFolders(defaultRoot: registered)
        try RecordingLibrary.rename(opened, title: "Renamed")
        let refreshed = RecordingLibrary.refreshed([opened])
        try expect(refreshed.count == 1 && refreshed[0].manifest.title == "Renamed")
        try expect(!folders.contains(external))
        try expect(RecordingLibrary.items(in: registered).isEmpty)
        try FileManager.default.moveItem(
            at: directory, to: root.appendingPathComponent("removed.mihrecording"))
        try expect(RecordingLibrary.refreshed(refreshed).isEmpty)
        try expect(!folders.contains(external))
    }

    func replacedDirectPackageDoesNotBecomeThePreviouslyOpenedSession() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString + ".mihrecording")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try RecordingManifest(title: "First", owner: .manual).save(to: directory)
        let opened = try RecordingLibrary.item(at: directory)
        try RecordingManifest(title: "Replacement", owner: .manual).save(to: directory)
        try expect(RecordingLibrary.refreshed([opened]).isEmpty)
        try expect(RecordingLibrary.item(at: directory).id != opened.id)
    }
}
