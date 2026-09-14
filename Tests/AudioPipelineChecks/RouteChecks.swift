import BridgeCore
import Darwin
import Foundation
import RecorderKit

enum RouteCheckFailure: Error { case failed(String) }

func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw RouteCheckFailure.failed(message) }
}

@main struct RouteChecks {
    static func main() async {
        var failures = 0
        do { try await successfulOutputCannotEraseCaptureFailure() } catch {
            failures += 1
            print("FAIL: \(error)")
        }
        do { try await pauseReleasesCapturesAndTapUntilResume() } catch {
            failures += 1
            print("FAIL: \(error)")
        }
        do { try await closingRecoveredViewPreservesItsDraft() } catch {
            failures += 1
            print("FAIL: \(error)")
        }
        if failures > 0 { exit(1) }
        print("Pipeline capture errors, pause ownership, and recovered session navigation passed.")
    }

    @MainActor static func closingRecoveredViewPreservesItsDraft() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(draftRoot: root)
        var state = try SessionState(name: "Recovered session", description: "")
        try state.start(at: 0)
        let metadata = try SessionManifest(state: state, createdAt: .now)
        let directory = try store.createDraft(metadata)
        try RecordingManifest(id: state.id, title: state.name, createdAt: metadata.createdAt, owner: .manual)
            .save(to: directory)
        let controller = SessionController(draftRoot: root)
        let draft = try store.drafts()[0]
        try await controller.restoreDraft(draft)
        try require(controller.closed && !controller.active, "A recovered draft must be closed")
        try require(controller.dismissClosed(), "A recovered draft must allow returning without saving")
        try require(
            controller.state == nil && controller.directory == nil, "Dismiss must release presentation")
        let retained = try store.drafts()
        try require(
            retained.count == 1 && retained[0].manifest.id == state.id, "Dismiss must preserve the draft")
        try await controller.restoreDraft(retained[0])
        try require(controller.state?.id == state.id, "A dismissed draft must remain reopenable")
        _ = controller.dismissClosed()
        try controller.showPreview(name: "Active", description: "")
        try require(
            !controller.dismissClosed() && controller.state != nil, "Dismiss must not end an active session")
        controller.closePreview()
    }

    static func start(_ pipeline: AudioPipeline, at directory: URL) async throws {
        try await pipeline.startSession(
            directory: directory,
            manifest: RecordingManifest(id: UUID(), title: "Route check", owner: .manual))
    }

    static func successfulOutputCannotEraseCaptureFailure() async throws {
        TestDevices.state.withLock { $0.rejectedCapture = 11 }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let pipeline = AudioPipeline()
        pipeline.configure(
            callerID: 11, agentInputID: 12, replyID: nil, monitorID: nil, agentTarget: nil)
        try await start(pipeline, at: root)
        let snapshot = pipeline.snapshot()
        _ = try await pipeline.finishSession()
        TestDevices.state.withLock { $0.rejectedCapture = nil }
        try require(!snapshot.callerReady, "Failed capture was reported ready")
        try require(
            snapshot.callerError == .audio(.errorConnectDevice, 11, nil),
            "Successful output erased the capture error")
    }

    static func pauseReleasesCapturesAndTapUntilResume() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let application = try ApplicationIdentity(
            bundleIdentifier: "com.example.agent", bundleURL: root.appendingPathComponent("Agent.app"),
            name: "Agent")
        let target = AppAudioTarget(application: application, processes: [101])
        let pipeline = AudioPipeline()
        func configure() {
            pipeline.configure(
                callerID: 11, agentInputID: 12, replyID: 13, monitorID: 14, agentTarget: target)
        }
        configure()
        try await start(pipeline, at: root)
        try require(TestDevices.state.withLock { $0.captures == 2 && $0.taps == 1 }, "Capture not started")
        _ = await pipeline.setControls(relaying: false, recording: false)
        configure()
        // A second queued control also joins the preceding configuration update.
        _ = await pipeline.setControls(relaying: false, recording: false)
        let paused = TestDevices.state.withLock { $0 }
        _ = await pipeline.setControls(relaying: true, recording: true)
        let resumed = TestDevices.state.withLock { $0 }
        _ = try await pipeline.finishSession()
        try require(
            paused.captures == 0 && paused.taps == 0 && paused.outputs == 0,
            "Pause retained a capture or a muting tap")
        try require(
            resumed.captures == 2 && resumed.taps == 1 && resumed.outputs == 3,
            "Resume did not recreate the current route")
        try require(
            TestDevices.state.withLock { $0.captures == 0 && $0.taps == 0 && $0.outputs == 0 },
            "Finish retained route resources")
    }
}
