import BridgeCore
import Foundation

struct RecordingFolderChecks {
    func firstChoiceUsesDocumentsAndRequiresConfirmation() throws {
        let documents = URL(fileURLWithPath: "/tmp/FolderChoice/Documents", isDirectory: true)
        let choice = RecordingFolderChoice(documentsDirectory: documents, savedPath: nil)
        try expect(choice.url == documents.appendingPathComponent("Switchboard", isDirectory: true))
        try expect(choice.requiresConfirmation)
    }

    func savedChoicesArePreservedAndInvalidValuesAskAgain() throws {
        let documents = URL(fileURLWithPath: "/tmp/FolderChoice/Documents", isDirectory: true)
        let chosen = RecordingFolderChoice(documentsDirectory: documents, savedPath: "/tmp/Chosen")
        try expect(chosen.url.path == "/tmp/Chosen" && !chosen.requiresConfirmation)
        for invalid in ["", "relative/path", "https://example.com", "/tmp/invalid\0path"] {
            try expect(
                RecordingFolderChoice(documentsDirectory: documents, savedPath: invalid).requiresConfirmation)
        }
    }

    func preparingFolderPreservesContentsAndRemovesProbe() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Documents/Switchboard", isDirectory: true)
        let prepared = try RecordingFolderChoice.prepare(folder)
        let original = prepared.appendingPathComponent("existing.txt")
        try Data("keep this file".utf8).write(to: original)
        _ = try RecordingFolderChoice.prepare(folder)
        try expect(try Data(contentsOf: original) == Data("keep this file".utf8))
        try expect(try FileManager.default.contentsOfDirectory(atPath: prepared.path) == ["existing.txt"])
    }

    func anExistingFileCannotBecomeASaveFolder() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let data = Data("original".utf8)
        try data.write(to: file)
        try expectThrows { _ = try RecordingFolderChoice.prepare(file) }
        try expect(try Data(contentsOf: file) == data)
    }

    func previousDefaultIsPreservedWithoutAskingAgain() throws {
        let documents = URL(fileURLWithPath: "/tmp/Documents", isDirectory: true)
        let previous = URL(fileURLWithPath: "/tmp/Music/Switchboard/Recordings", isDirectory: true)
        let choice = RecordingFolderChoice(
            documentsDirectory: documents, savedPath: nil, previousDefault: previous)
        try expect(choice.url == previous && !choice.requiresConfirmation)
        let custom = RecordingFolderChoice(
            documentsDirectory: documents, savedPath: "/tmp/Chosen", previousDefault: previous)
        try expect(custom.url.path == "/tmp/Chosen" && !custom.requiresConfirmation)
    }
}
