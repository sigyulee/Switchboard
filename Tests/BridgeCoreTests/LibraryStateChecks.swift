import BridgeCore
import Foundation
import RecorderKit

struct LibraryStateChecks {
    @MainActor
    func periodicRefreshLetsASlowScanPublish() async throws {
        let root = temporaryRoot()
        let directory = root.appendingPathComponent("fixture.mihrecording")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var manifest = RecordingManifest(title: "Slow folder fixture", owner: .manual)
        manifest.status = .complete
        try manifest.save(to: directory)
        let queue = AsyncSerialQueue(label: "library-check.slow-scan")
        let entered = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        var state = LibraryRefreshState()
        guard let first = state.request(root: root) else {
            throw CheckFailure(description: "initial library scan was not accepted")
        }
        let scan = Task {
            defer { entered.continuation.finish() }
            return try await queue.run {
                entered.continuation.yield(())
                guard release.wait(timeout: .now() + 5) == .success else {
                    throw CheckFailure(description: "slow library scan gate timed out")
                }
                return try RecordingLibrary.items(in: root)
            }
        }
        for await _ in entered.stream { break }
        let replacements = (0..<50).compactMap { _ in state.request(root: root) }
        release.signal()
        let items = try await scan.value
        let published = state.canPublish(first) ? items : []
        let followup = state.finish(first)
        try expect(published.map(\.id) == [manifest.id])
        try expect(replacements.isEmpty)
        try expect(followup == nil && state.current == nil)
    }

    func changesCoalesceIntoOneFollowup() throws {
        let root = temporaryRoot()
        var state = LibraryRefreshState()
        guard let first = state.request(root: root) else {
            throw CheckFailure(description: "initial library scan was not accepted")
        }
        let replacements = (0..<50).compactMap { _ in state.request(root: root, afterChange: true) }
        try expect(replacements.isEmpty)
        try expect(state.isCurrent(first))
        try expect(state.request(root: root) == nil)
        try expect(!state.canPublish(first))
        guard let followup = state.finish(first) else {
            throw CheckFailure(description: "a change during loading lost its follow-up scan")
        }
        try expect(followup.root == root && followup != first)
        try expect(state.canPublish(followup))
        try expect(state.finish(first) == nil && state.isCurrent(followup))
        try expect(state.finish(followup) == nil && state.current == nil)
    }

    func staleCompletionsCannotClearNewRootsOrRestartShutdown() throws {
        let firstRoot = temporaryRoot()
        let otherRoot = temporaryRoot()
        var state = LibraryRefreshState()
        guard let first = state.request(root: firstRoot),
            let other = state.request(root: otherRoot),
            let latest = state.request(root: firstRoot)
        else { throw CheckFailure(description: "replacement library scan was not accepted") }
        try expect(!state.isCurrent(first) && !state.isCurrent(other))
        try expect(state.finish(first) == nil && state.finish(other) == nil)
        try expect(state.isCurrent(latest))
        _ = state.request(root: firstRoot, afterChange: true)
        state.shutdown()
        try expect(!state.isCurrent(latest))
        try expect(state.finish(latest) == nil)
        try expect(state.request(root: firstRoot) == nil && state.current == nil)
    }

    func pendingRecordingProtectsFolderAndLibraryActions() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = ConversationRecorder()
        let directory = try recorder.start(root: root, owner: .manual)
        defer { _ = try? recorder.finish(durationFrames: 0) }
        let access = RecordingLibraryAccess(
            preview: false, starting: true, recordingDirectory: nil, finalizing: [])
        let items = try RecordingLibrary.items(in: root)
        try expect(items.count == 1 && items[0].manifest.status == .recording)
        // This is the startup window after archive creation and before audio attachment
        // publishes recordingDirectory. All mutation entry points share canEdit.
        try expect(!access.canChangeFolder)
        try expect(!access.canEdit(directory))
        try expect(!access.canRecover(directory, status: .recording))
        try expect(!access.canEdit(root.appendingPathComponent("older.mihrecording")))
    }

    func pendingArchiveIsHiddenUntilOwnershipIsKnown() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = ConversationRecorder()
        let directory = try recorder.start(root: root, owner: .manual)
        defer { _ = try? recorder.finish(durationFrames: 0) }
        let pending = RecordingLibraryAccess(
            preview: false, starting: true, recordingDirectory: nil, finalizing: [])
        let items = try RecordingLibrary.items(in: root)
        let visible = items.filter { pending.canDisplay($0.directory, status: $0.manifest.status) }
        try expect(visible.isEmpty)
        try expect(pending.canDisplay(root.appendingPathComponent("older.mihrecording"), status: .complete))
        let attached = RecordingLibraryAccess(
            preview: false, starting: false, recordingDirectory: directory, finalizing: [])
        try expect(attached.canDisplay(directory, status: .recording))
        try expect(!attached.canEdit(directory) && !attached.canRecover(directory, status: .recording))
    }

    func libraryAccessPreservesActiveAndFinalizingOwnership() throws {
        let root = temporaryRoot()
        let active = root.appendingPathComponent("active.mihrecording")
        let finishing = root.appendingPathComponent("finishing.mihrecording")
        let older = root.appendingPathComponent("older.mihrecording")
        let access = RecordingLibraryAccess(
            preview: false, starting: false, recordingDirectory: active, finalizing: [finishing])
        try expect(!access.canChangeFolder)
        try expect(!access.canEdit(active) && !access.canEdit(finishing))
        try expect(!access.canRecover(active, status: .recording))
        try expect(!access.canRecover(finishing, status: .finalizing))
        try expect(access.canEdit(older) && access.canRecover(older, status: .recording))
        try expect(!access.canRecover(older, status: .complete))
        let idle = RecordingLibraryAccess(
            preview: false, starting: false, recordingDirectory: nil, finalizing: [])
        try expect(idle.canChangeFolder && idle.canEdit(older))
        let preview = RecordingLibraryAccess(
            preview: true, starting: false, recordingDirectory: nil, finalizing: [])
        try expect(!preview.canChangeFolder && !preview.canEdit(older))
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("library-check-\(UUID().uuidString)")
    }
}
