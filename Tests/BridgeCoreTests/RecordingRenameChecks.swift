import BridgeCore
import Foundation
import RecorderKit

struct RecordingRenameChecks {
    func renameUpdatesStoredNamesAndPreservesSessionHistoryAndPayloads() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        for (index, format) in [(true, false), (true, true), (false, true)].enumerated() {
            let item = try fixture(in: root.appendingPathComponent("\(index)"), format: format)
            let before = try contents(of: item.directory)
            let originalSession = format.1 ? try SessionStore.metadata(in: item.directory) : nil
            try RecordingLibrary.rename(item, title: "  새 이름 / Renamed\n")
            let current = try RecordingLibrary.item(at: item.directory)
            var expected = item.manifest
            expected.title = "새 이름 / Renamed"
            try expect(current.directory == item.directory && current.manifest == expected)
            var payloadBefore = before
            var payloadAfter = try contents(of: item.directory)
            for filename in ["manifest.json", SessionManifest.filename] {
                payloadBefore.removeValue(forKey: filename)
                payloadAfter.removeValue(forKey: filename)
            }
            try expect(payloadAfter == payloadBefore)
            if let originalSession {
                let currentSession = try SessionStore.metadata(in: item.directory)
                try expect(currentSession.title == expected.title)
                try expect(currentSession.id == originalSession.id)
                try expect(currentSession.createdAt == originalSession.createdAt)
                try expect(currentSession.description == originalSession.description)
                try expect(currentSession.isDraft == originalSession.isDraft)
                try expect(currentSession.durationFrames == originalSession.durationFrames)
                try expect(currentSession.state.lifecycle == originalSession.state.lifecycle)
                try expect(currentSession.state.pauseReason == originalSession.state.pauseReason)
                try expect(currentSession.state.audioRecording == originalSession.state.audioRecording)
                try expect(currentSession.state.transcription == originalSession.state.transcription)
                try expect(
                    currentSession.state.recordingIntervals == originalSession.state.recordingIntervals)
                try expect(
                    currentSession.state.transcriptionIntervals
                        == originalSession.state.transcriptionIntervals)
            } else {
                try expect(contents(of: item.directory)[SessionManifest.filename] == nil)
            }
            let bytesAfter = try contents(of: item.directory)
            try RecordingLibrary.rename(current, title: expected.title)
            try expect(contents(of: item.directory) == bytesAfter)
        }
    }

    func invalidNamesAndReplacedSourcesAreRejectedWithoutWriting() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        for legacy in [false, true] {
            let item = try fixture(
                in: root.appendingPathComponent("\(legacy)"), format: (legacy, !legacy))
            let before = try contents(of: item.directory)
            for title in [
                "", " \n", "Invalid\0name", String(repeating: "a", count: 513),
                String(repeating: "가", count: 171),
            ] {
                try expectThrows { try RecordingLibrary.rename(item, title: title) }
                try expect(contents(of: item.directory) == before)
            }
            var wrongIdentity = item.manifest
            wrongIdentity.id = UUID()
            let selected = RecordingItem(directory: item.directory, manifest: wrongIdentity)
            try expectThrows { try RecordingLibrary.rename(selected, title: "Wrong session") }
            wrongIdentity = item.manifest
            wrongIdentity.createdAt.addTimeInterval(1)
            let wrongDate = RecordingItem(directory: item.directory, manifest: wrongIdentity)
            try expectThrows { try RecordingLibrary.rename(wrongDate, title: "Wrong creation date") }
            try expect(contents(of: item.directory) == before)
        }
    }

    func secondMetadataReplacementFailureRestoresOriginalBytes() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let item = try fixture(in: root, format: (false, true))
        let before = try contents(of: item.directory)
        let sessionPath = item.directory.appendingPathComponent(SessionManifest.filename).path
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: sessionPath)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: sessionPath) }
        try expectThrows { try RecordingLibrary.rename(item, title: "Must roll back") }
        try expect(contents(of: item.directory) == before)
        try expect(RecordingLibrary.item(at: item.directory).manifest == item.manifest)
        try expect(SessionStore.metadata(in: item.directory).title == item.manifest.title)
        try expect(noStaging(in: item.directory))
    }

    func linkedMetadataIsRejectedWithoutChangingItsTarget() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        for filename in ["manifest.json", SessionManifest.filename] {
            let item = try fixture(in: root.appendingPathComponent(filename), format: (false, true))
            let original = item.directory.appendingPathComponent(filename)
            let outside = item.directory.deletingLastPathComponent().appendingPathComponent("outside.json")
            try FileManager.default.moveItem(at: original, to: outside)
            try FileManager.default.createSymbolicLink(at: original, withDestinationURL: outside)
            let before = try Data(contentsOf: outside)
            try expectThrows { try RecordingLibrary.rename(item, title: "Refuse linked metadata") }
            try expect(Data(contentsOf: outside) == before && noStaging(in: item.directory))
        }
    }

    private func fixture(in root: URL, format: (Bool, Bool)) throws -> RecordingItem {
        let directory = root.appendingPathComponent(
            format.0 ? "Original.mihrecording" : "Original.switchboard")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var recording = RecordingManifest(title: "Original name", owner: .automatic)
        recording.durationFrames = 960
        recording.status = .complete
        try recording.save(to: directory)
        if format.1 {
            var state = try SessionState(id: recording.id, name: recording.title, description: "설명\nNotes")
            try state.start()
            try state.setTranscription(true, at: 120)
            try state.setAudioRecording(false, at: 480)
            try state.pause(at: 960, reason: .manual)
            let session = try SessionManifest(state: state, createdAt: recording.createdAt, isDraft: true)
            try JSONEncoder().encode(session).write(
                to: directory.appendingPathComponent(SessionManifest.filename))
        }
        for (name, text) in [
            ("Conversation.m4a", "Preserve the rendered audio"),
            ("caller-0.caf", "Preserve the source audio"),
            ("transcript.jsonl", "Preserve transcription and translation bytes"),
        ] {
            try Data(text.utf8).write(to: directory.appendingPathComponent(name))
        }
        return try RecordingLibrary.item(at: directory)
    }

    private func contents(of directory: URL) throws -> [String: Data] {
        var result: [String: Data] = [:]
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        {
            if try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
                for (path, data) in try contents(of: url) {
                    result[url.lastPathComponent + "/" + path] = data
                }
            } else {
                result[url.lastPathComponent] = try Data(contentsOf: url)
            }
        }
        return result
    }

    private func noStaging(in directory: URL) throws -> Bool {
        try !FileManager.default.contentsOfDirectory(atPath: directory.path).contains {
            $0.hasSuffix(".staging")
        }
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("recording-rename-\(UUID().uuidString)")
    }
}
