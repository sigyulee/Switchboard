import BridgeCore
import Darwin
import Foundation
import Observation
import RecorderKit
import Synchronization

private struct PresentationCheckFailure: Error, CustomStringConvertible {
    let description: String
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw PresentationCheckFailure(description: message) }
}

private final class PresentationChanges: Sendable {
    private let storage = Mutex(0)
    var count: Int { storage.withLock { $0 } }
    func record() { storage.withLock { $0 += 1 } }
}

@main @MainActor struct SessionPresentationChecks {
    static func main() async {
        let checks: [(String, @MainActor () async throws -> Void)] = [
            (
                "elapsed updates notify the timeline without invalidating controls",
                elapsedUpdatesPreserveControls
            ),
            ("unchanged elapsed frames do not invalidate the timeline", unchangedElapsedPreservesObservation),
            (
                "pause resume and independent controls keep their presentation",
                lifecycleControlsStayConsistent
            ),
            (
                "restored drafts and dismissed views keep their presentation",
                restoredDraftsAndCloseStayConsistent
            ),
        ]
        var failures = 0
        for (name, check) in checks {
            do {
                try await check()
                print("PASS \(name)")
            } catch {
                failures += 1
                print("FAIL \(name): \(error)")
            }
        }
        if failures > 0 { exit(1) }
        print("\(checks.count) session presentation checks passed with substituted hardware boundaries.")
    }

    private static func elapsedUpdatesPreserveControls() async throws {
        try await withController { controller, _ in
            let id = UUID()
            try require(
                !controller.hasSession && controller.sessionID == nil,
                "An empty controller reported a session")
            try controller.showPreview(id: id, name: "Preview", description: "Clock regression")
            try require(
                controller.hasSession && controller.sessionID == id, "Preview identity was not presented")
            try require(
                controller.sessionName == "Preview" && controller.sessionDescription == "Clock regression",
                "Preview headings are stale")
            let controls = observeControls(controller)
            for tick in 1...10 {
                let timeline = PresentationChanges()
                withObservationTracking {
                    _ = controller.duration
                } onChange: {
                    timeline.record()
                }
                controller.updateElapsed(Double(tick) / 10)
                try require(
                    timeline.count == 1, "A real clock tick failed to invalidate its duration observer")
                try require(
                    controller.state?.durationFrames == Int64(tick) * 4800, "A real clock tick was throttled")
            }
            try require(controls.count == 0, "Clock ticks invalidated unchanged session controls")
            try require(controller.duration == 1, "The presentation change altered elapsed time")
            try require(controller.state?.durationFrames == 48_000, "The authoritative frame count changed")
            try require(
                controller.state?.recordingIntervals.count == 1, "Clock updates changed recording intervals")
            try require(
                controller.state?.recordingIntervals.first?.frames == 48_000,
                "Clock updates lost recorded frames")
        }
    }

    private static func unchangedElapsedPreservesObservation() async throws {
        try await withController { controller, _ in
            try controller.showPreview(name: "Preview", description: "Repeated frame")
            controller.updateElapsed(1)
            let previous = controller.state
            let changes = PresentationChanges()
            withObservationTracking {
                _ = controller.state
                _ = controller.duration
            } onChange: {
                changes.record()
            }
            for seconds in [
                1, 0.5, 1 + 1 / 96_000, -1, Double.nan, .infinity, Double.greatestFiniteMagnitude,
            ] {
                controller.updateElapsed(seconds)
            }
            try require(changes.count == 0, "An unchanged or invalid clock reading published session state")
            try require(controller.state == previous, "An unchanged or invalid clock reading altered state")
            controller.updateElapsed(2)
            try require(changes.count == 1, "A later real clock update failed to publish")
            try require(
                controller.state?.durationFrames == 96_000,
                "A real clock update was throttled or rounded away")
        }
    }

    private static func lifecycleControlsStayConsistent() async throws {
        try await withController { controller, _ in
            try controller.showPreview(name: "Preview", description: "Lifecycle")
            controller.updateElapsed(1)
            let running = observeControls(controller)
            try await controller.pause(reason: .callerDisconnected)
            try require(running.count == 1, "Pausing did not invalidate active controls")
            try require(
                controller.active && controller.paused && !controller.running, "Pause flags are stale")
            try require(
                !controller.recording && controller.audioRecordingEnabled, "Pause lost the recording choice")
            try require(controller.pauseReason == .callerDisconnected, "Pause lost its reason")
            let paused = observeControls(controller)
            try await controller.pause()
            try await controller.pause()
            controller.updateElapsed(2)
            try require(
                paused.count == 0, "Repeated pause or its elapsed clock invalidated unchanged controls")
            try require(controller.duration == 2, "Paused session time stopped advancing")
            try await controller.resume()
            try require(paused.count == 1, "Resuming failed to invalidate paused controls")
            try require(
                controller.active && controller.running && controller.recording && !controller.paused,
                "Resume flags are stale")
            try require(controller.pauseReason == nil, "Resuming retained a stale pause reason")
            try await controller.setRecording(false)
            try require(
                !controller.recording && !controller.audioRecordingEnabled && controller.running,
                "Recording off changed session relay state")
            let unchanged = observeControls(controller)
            try await controller.setRecording(false)
            try require(unchanged.count == 0, "Repeating recording off invalidated unchanged controls")
            _ = try await controller.setTranscription(true)
            try require(
                controller.transcriptionEnabled && !controller.recording, "Transcription changed recording")
            _ = try await controller.setTranscription(false)
            try await controller.setRecording(true)
            try require(
                controller.recording && !controller.transcriptionEnabled, "Independent controls drifted")
            let closing = observeControls(controller)
            controller.closePreview()
            try require(closing.count == 1, "Closing a preview did not invalidate its presentation")
            try require(
                !controller.active && !controller.running && !controller.paused && !controller.recording,
                "Closing the preview left active flags")
            try require(
                !controller.hasSession && controller.sessionID == nil, "Closing left a stale session identity"
            )
            try require(
                controller.sessionName.isEmpty && controller.sessionDescription.isEmpty,
                "Closing left stale headings")
        }
    }

    private static func restoredDraftsAndCloseStayConsistent() async throws {
        try await withController { controller, root in
            let store = SessionStore(draftRoot: root)
            var state = try SessionState(name: "Recovered", description: "Retained draft")
            try state.start(at: 0)
            try state.pause(at: 48_000)
            let metadata = try SessionManifest(state: state)
            let directory = try store.createDraft(metadata)
            var audio = RecordingManifest(
                id: state.id, title: state.name, createdAt: metadata.createdAt, owner: .manual)
            audio.durationFrames = 48_000
            try audio.save(to: directory)
            guard let draft = try store.drafts().first else {
                throw PresentationCheckFailure(description: "The temporary draft was not created")
            }
            try await controller.restoreDraft(draft)
            try require(controller.closed && !controller.active, "A restored draft was reported active")
            try require(
                !controller.running && !controller.paused && !controller.recording,
                "Recovered lifecycle flags are stale")
            try require(
                controller.state?.id == state.id && controller.duration == 1,
                "Recovery changed session identity or time")
            try require(
                controller.hasSession && controller.sessionID == state.id,
                "Recovery left a stale presentation identity")
            try require(
                controller.sessionName == "Recovered" && controller.sessionDescription == "Retained draft",
                "Recovery did not restore headings")
            try require(
                controller.audioRecordingEnabled && !controller.transcriptionEnabled,
                "Recovery lost the stored control choices")
            let closed = observeControls(controller)
            controller.updateElapsed(20)
            try await controller.pause()
            try await controller.resume()
            try require(closed.count == 0, "A closed draft published unchanged controls")
            try require(controller.dismissClosed(), "The recovered view could not be dismissed")
            try require(
                controller.state == nil && !controller.closed && !controller.active,
                "Dismiss did not reset presentation")
            try require(
                !controller.hasSession && controller.sessionID == nil,
                "Dismiss retained the recovered identity")
            try controller.showPreview(name: "New", description: "")
            try require(
                controller.active && controller.running && controller.recording,
                "The next preview inherited closed flags")
            controller.closePreview()
        }
    }

    private static func observeControls(_ controller: SessionController) -> PresentationChanges {
        let changes = PresentationChanges()
        withObservationTracking {
            _ = controller.active
            _ = controller.running
            _ = controller.paused
            _ = controller.recording
            _ = controller.hasSession
            _ = controller.sessionID
            _ = controller.sessionName
            _ = controller.sessionDescription
            _ = controller.audioRecordingEnabled
            _ = controller.transcriptionEnabled
            _ = controller.pauseReason
        } onChange: {
            changes.record()
        }
        return changes
    }

    private static func withController(_ operation: (SessionController, URL) async throws -> Void)
        async throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = SessionController(draftRoot: root)
        do {
            try await operation(controller, root)
        } catch {
            await controller.pipeline.shutdownRoutes()
            throw error
        }
        await controller.pipeline.shutdownRoutes()
        try require(
            TestDevices.state.withLock { $0.captures == 0 && $0.outputs == 0 && $0.taps == 0 },
            "Presentation-only checks unexpectedly opened audio routes")
    }
}
