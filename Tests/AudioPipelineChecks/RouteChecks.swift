import AudioRealtime
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
        do { try await monitoringUpdatesKeepRelayOwnership() } catch {
            failures += 1
            print("FAIL: \(error)")
        }
        do { try await monitoringGainsDoNotAffectRelay() } catch {
            failures += 1
            print("FAIL: \(error)")
        }
        if failures > 0 { exit(1) }
        print(
            "Pipeline capture errors, pause ownership, monitoring updates/gains, and recovered session navigation passed."
        )
    }

    static func monitoringGainsDoNotAffectRelay() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let application = try ApplicationIdentity(
            bundleIdentifier: "com.example.agent",
            bundleURL: root.appendingPathComponent("Agent.app"), name: "Agent")
        let pipeline = AudioPipeline()
        pipeline.configure(
            callerID: 11, agentInputID: 12, replyID: 13, monitorID: 14,
            agentTarget: AppAudioTarget(application: application, processes: [101]))
        try await start(pipeline, at: root)
        _ = await pipeline.setControls(relaying: true, recording: false)
        do {
            for (callerGain, agentGain, expected) in [(Float(0.5), Float(0.25), Float(0.2)), (0, 1, 0.4)] {
                pipeline.configureMonitoring(monitorID: 14, callerVolume: callerGain, agentVolume: agentGain)
                _ = await pipeline.currentSessionFrame()
                let host = sb_host_time()
                TestDevices.state.withLock { state in
                    state.outputPeaks.removeValue(forKey: 14)
                    state.pendingPackets[11] = ([Float](repeating: 0.4, count: 96_000), host)
                    state.pendingPackets[42] = ([Float](repeating: 0.8, count: 96_000), host)
                }
                for _ in 0..<200 {
                    if TestDevices.state.withLock({ abs(($0.outputPeaks[14] ?? 0) - expected) < 0.0001 }) {
                        break
                    }
                    try await Task.sleep(for: .milliseconds(2))
                }
                try require(
                    TestDevices.state.withLock { abs(($0.outputPeaks[14] ?? 0) - expected) < 0.0001 },
                    "Monitor mix did not use the latest independent volume settings")
                try require(
                    TestDevices.state.withLock { $0.outputPeaks[12] == 0.4 && $0.outputPeaks[13] == 0.8 },
                    "Monitoring volume changed the relayed Caller or Agent audio")
            }
        } catch {
            _ = try? await pipeline.finishSession()
            throw error
        }
        _ = try await pipeline.finishSession()
    }

    static func monitoringUpdatesKeepRelayOwnership() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let application = try ApplicationIdentity(
            bundleIdentifier: "com.example.agent",
            bundleURL: root.appendingPathComponent("Agent.app"), name: "Agent")
        let pipeline = AudioPipeline()
        pipeline.configure(
            callerID: 11, agentInputID: 12, replyID: 13, monitorID: 14,
            agentTarget: AppAudioTarget(application: application, processes: [101]))
        try await start(pipeline, at: root)
        do {
            let before = TestDevices.state.withLock { $0 }
            for step in 0..<100 {
                pipeline.configureMonitoring(
                    monitorID: 14, callerVolume: Float(step) / 100,
                    agentVolume: 1 - Float(step) / 100)
            }
            _ = await pipeline.currentSessionFrame()
            let volumes = TestDevices.state.withLock { $0 }
            try require(
                volumes.captureStarts == before.captureStarts && volumes.tapStarts == before.tapStarts,
                "Changing volume restarted capture or the selected Agent tap")
            pipeline.configureMonitoring(monitorID: 15, callerVolume: 0.2, agentVolume: 0.8)
            _ = await pipeline.currentSessionFrame()
            try require(
                TestDevices.state.withLock {
                    $0.outputIDs == [12, 13, 15] && $0.captures == 2 && $0.taps == 1
                },
                "Changing monitor lost a relay endpoint or retained the previous output")
            TestDevices.state.withLock { $0.rejectedOutput = 16 }
            pipeline.configureMonitoring(monitorID: 16, callerVolume: 0.2, agentVolume: 0.8)
            _ = await pipeline.currentSessionFrame()
            let failure = pipeline.snapshot()
            TestDevices.state.withLock { $0.rejectedOutput = nil }
            try require(
                failure.monitorError == .audio(.errorConnectDevice, 16, nil)
                    && failure.callerReady && failure.agentReady,
                "Monitor failure was hidden or stopped independent relay routes")
            pipeline.configureMonitoring(monitorID: 15, callerVolume: 0.2, agentVolume: 0.8)
            _ = await pipeline.currentSessionFrame()
            try require(
                pipeline.snapshot().monitorError == nil && pipeline.snapshot().monitorReady,
                "Successful monitor selection retained the previous failure")
            _ = await pipeline.setControls(relaying: false, recording: false)
            pipeline.configureMonitoring(monitorID: 17, callerVolume: 0.3, agentVolume: 0.7)
            _ = await pipeline.currentSessionFrame()
            try require(
                TestDevices.state.withLock { $0.outputs == 0 && $0.captures == 0 && $0.taps == 0 },
                "Editing monitoring while paused reopened audio routes")
            _ = await pipeline.setControls(relaying: true, recording: false)
            try require(
                TestDevices.state.withLock { $0.outputIDs == [12, 13, 17] },
                "Resume lost the monitoring selection made while paused")
        } catch {
            TestDevices.state.withLock { $0.rejectedOutput = nil }
            _ = try? await pipeline.finishSession()
            throw error
        }
        _ = try await pipeline.finishSession()
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
