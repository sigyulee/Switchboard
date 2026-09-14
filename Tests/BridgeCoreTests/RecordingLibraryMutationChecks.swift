import BridgeCore
import Foundation
import RecorderKit

struct RecordingLibraryMutationChecks {
    func recoveryWaitsForOtherLibraryWork() throws {
        let directory = URL(fileURLWithPath: "/tmp/recovery.mihrecording")
        let access = RecordingLibraryAccess(
            preview: false, starting: false, recordingDirectory: nil, finalizing: [])
        try expect(access.canRecover(directory, status: .recoverable))
        try expect(!access.canRecover(directory, status: .recoverable, busy: true))
        try expect(!access.canRecover(directory, status: .failed, busy: true))
        try expect(access.canRecover(directory, status: .failed, busy: false))
        try expect(!access.canRecover(directory, status: .complete))
    }

    func staleRenamePreservesFinalizedMetadata() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try finalizedFixture(in: root)
        try RecordingLibrary.rename(fixture.stale, title: "Renamed after finalization")
        let saved = try RecordingManifest.load(from: fixture.stale.directory)
        try expect(saved.title == "Renamed after finalization")
        try expect(saved.status == .complete && saved.durationFrames == 4800)
        try expect(saved.segments == fixture.completed.manifest.segments)
        try expect(saved.gaps == fixture.completed.manifest.gaps)
        try expect(saved.id == fixture.completed.id && saved.failure == nil)
    }

    func staleRecoveryReturnsLatestCompleteArchiveWithoutWriting() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try finalizedFixture(in: root)
        var completed = fixture.completed.manifest
        completed.title = "Saved after the stale selection"
        try completed.save(to: fixture.stale.directory)
        let manifestURL = fixture.stale.directory.appendingPathComponent("manifest.json")
        let before = try Data(contentsOf: manifestURL)
        let recovered = try RecordingLibrary.recover(fixture.stale)
        try expect(recovered.manifest == completed)
        try expect(recovered.manifest.status == .complete)
        try expect(recovered.manifest.title == "Saved after the stale selection")
        try expect(try Data(contentsOf: manifestURL) == before)
    }

    func mutationsValidateTheLatestPersistedManifest() throws {
        let root = temporaryRoot()
        let directory = root.appendingPathComponent("fixture.mihrecording")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let stale = RecordingItem(
            directory: directory, manifest: RecordingManifest(title: "Stale selection", owner: .manual))
        var damaged = stale.manifest
        damaged.sampleRate = 0
        let bytes = try JSONEncoder().encode(damaged)
        let manifestURL = directory.appendingPathComponent("manifest.json")
        try bytes.write(to: manifestURL)
        try expectThrows { try RecordingLibrary.rename(stale, title: "Do not overwrite invalid metadata") }
        try expect(try Data(contentsOf: manifestURL) == bytes)
        try expectThrows { _ = try RecordingLibrary.recover(stale) }
        try expect(try Data(contentsOf: manifestURL) == bytes)
    }

    private func finalizedFixture(in root: URL) throws -> (stale: RecordingItem, completed: RecordingItem) {
        let recorder = ConversationRecorder()
        let directory = try recorder.start(root: root, owner: .manual)
        let stale = RecordingItem(directory: directory, manifest: try RecordingManifest.load(from: directory))
        try expect(stale.manifest.status == .recording && stale.manifest.segments.isEmpty)
        try expect(recorder.append(side: .caller, samples: [Float](repeating: 0.25, count: 9600), frame: 0))
        _ = try recorder.finish(durationFrames: 4800)
        let completed = try RecordingRenderer.finalize(directory: directory)
        try expect(completed.manifest.status == .complete)
        try expect(completed.manifest.segments.count == 1 && completed.manifest.durationFrames == 4800)
        return (stale, completed)
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "library-mutation-check-\(UUID().uuidString)")
    }
}
