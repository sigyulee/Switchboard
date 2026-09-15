import BridgeCore
import CoreAudio
import Darwin
import Foundation
import RecorderKit

private struct NavigationCheckFailure: Error, CustomStringConvertible {
    let description: String
}

private func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw NavigationCheckFailure(description: message) }
}

@main @MainActor struct NavigationChecks {
    static func main() async {
        let checks: [(String, @MainActor () async throws -> Void)] = [
            ("monitoring changes preserve discovery and remember the selected device", monitoringChanges),
            ("monitoring fallback preserves the selected device across reconnect", monitoringReconnect),
            ("fresh installation confirms a folder before audio setup and remembers it", firstRunFolder),
            ("failed and cancelled folder choices preserve first-run state", failedFolderChoice),
            ("upgrading preserves configured and implicit save folders", existingFolderChoice),
            ("external file opening preserves selection while restoring a draft", fileOpenWhileOpeningDraft),
            ("external file opening preserves selection while ending a session", fileOpenWhileEndingSession),
            (
                "closing an archived draft clears its selection and preserves its package",
                closeAndRestoreDraft
            ),
            ("opening a saved recording retains its selection when closing a draft", selectSavedFromDraft),
            (
                "playback source follows the latest request and resets on recording changes",
                playbackSourceSelection
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
        print(
            "\(checks.count) library navigation checks passed; no audio or permission requests were started.")
    }

    private static func monitoringChanges() async throws {
        try await withFreshModel { model, defaults, _ in
            model.language = .english
            let devices = monitoringDevices()
            model.devices = devices
            let applications = model.applications
            model.preferredUID = "test-usb"
            model.callerVolume = 0.35
            model.agentVolume = 0.65
            model.refreshMonitoring()
            try require(
                model.devices == devices && model.applications == applications,
                "A monitoring edit performed full device/application discovery")
            try require(
                model.callerVolume == 0.35 && model.agentVolume == 0.65,
                "Monitoring update changed independent volume values")
            try require(
                defaults.string(forKey: "monitorName") == "USB Headphones",
                "Selected monitoring device name was not remembered")
            model.preferredUID = "test-built-in"
            model.refreshMonitoring()
            try require(
                defaults.string(forKey: "monitorName") == "Built-in Speakers",
                "Monitoring device change retained the previous name")
        }
    }

    private static func monitoringReconnect() async throws {
        try await withFreshModel { model, _, _ in
            model.language = .english
            let devices = monitoringDevices()
            model.devices = devices
            model.preferredUID = "test-usb"
            model.refreshMonitoring()
            model.devices = [devices[0]]
            model.speakerFallback = false
            model.refreshMonitoring()
            try require(model.monitorDevice == nil, "Fallback off enabled another output")
            try require(model.preferredOutputName == "USB Headphones", "Disconnected device lost its name")
            model.speakerFallback = true
            model.refreshMonitoring()
            try require(
                model.monitorDevice?.uid == "test-built-in", "Fallback did not select built-in speakers")
            try require(model.preferredUID == "test-usb", "Fallback replaced the selected device")
            model.devices = devices
            model.refreshMonitoring()
            try require(
                model.monitorDevice?.uid == "test-usb", "Reconnect did not return to the selected device")
        }
    }

    private static func monitoringDevices() -> [AudioDevice] {
        [
            AudioDevice(
                id: 901, uid: "test-built-in", name: "Built-in Speakers", input: false,
                output: true, transport: kAudioDeviceTransportTypeBuiltIn, alive: true),
            AudioDevice(
                id: 902, uid: "test-usb", name: "USB Headphones", input: false,
                output: true, transport: kAudioDeviceTransportTypeUSB, alive: true),
        ]
    }

    private static func firstRunFolder() async throws {
        try await withFreshModel { model, defaults, storage in
            let proposed = storage.documents.appendingPathComponent("Switchboard", isDirectory: true)
            try require(
                model.language == nil && model.needsRecordingFolderSetup, "Fresh state skipped onboarding")
            try require(model.recordingRoot == proposed, "Fresh state did not propose Documents/Switchboard")
            try require(
                !FileManager.default.fileExists(atPath: proposed.path),
                "The proposal created a folder without confirmation")
            model.boot()
            model.chooseLanguage(.english)
            try require(
                !model.showSetup && !model.canStartSession, "Audio setup or Start preceded the folder choice")
            // Relaunch between language and folder choice must resume the folder step.
            let interrupted = AppModel(preview: false, defaults: defaults, storage: storage)
            try require(
                interrupted.language == .english && interrupted.needsRecordingFolderSetup,
                "Relaunch skipped the pending choice")
            await interrupted.shutdown()
            model.useRecordingFolder(proposed)
            try await waitForFolder(model)
            try require(
                model.recordingFolderIssue == nil && !model.needsRecordingFolderSetup,
                "Successful confirmation did not advance")
            try require(
                defaults.string(forKey: "recordingRoot") == proposed.path, "The chosen folder was not saved")
            try require(
                model.showSetup == model.requiresSetup, "Audio setup did not follow folder confirmation")
            try require(
                try FileManager.default.contentsOfDirectory(atPath: proposed.path).isEmpty,
                "Folder confirmation left temporary files")
            let reopened = AppModel(preview: false, defaults: defaults, storage: storage)
            try require(
                !reopened.needsRecordingFolderSetup && reopened.recordingRoot == proposed,
                "A completed choice was prompted again")
            await reopened.shutdown()
        }
    }

    private static func failedFolderChoice() async throws {
        try await withFreshModel { model, defaults, storage in
            model.chooseLanguage(.korean)
            let proposed = model.recordingRoot
            let file = storage.documents.deletingLastPathComponent().appendingPathComponent("existing.txt")
            let bytes = Data("Keep this file".utf8)
            try bytes.write(to: file)
            model.useRecordingFolder(file)
            try await waitForFolder(model)
            try require(
                model.recordingFolderIssue != nil && model.needsRecordingFolderSetup,
                "A failed folder did not retain an inline error")
            try require(
                model.recordingRoot == proposed && defaults.string(forKey: "recordingRoot") == nil,
                "A failed choice changed the saved folder")
            try require(!model.showSetup && !model.canStartSession, "A failed choice advanced setup")
            try require(try Data(contentsOf: file) == bytes, "A failed choice changed the existing file")
            let custom = storage.documents.deletingLastPathComponent().appendingPathComponent(
                "Custom", isDirectory: true)
            model.useRecordingFolder(custom)
            // Cancel without yielding: a completed worker still cannot publish after shutdown.
            await model.shutdown()
            try require(
                model.needsRecordingFolderSetup && defaults.string(forKey: "recordingRoot") == nil,
                "Cancelled folder preparation published a late result")
        }
    }

    private static func existingFolderChoice() async throws {
        try await withFreshModel { _, defaults, storage in
            defaults.set(true, forKey: "legacyPreferencesMigrated")
            ApplicationLanguage.korean.save(in: defaults)
            defaults.set("headphones", forKey: "monitorUID")
            for saved in [nil, "/tmp/Previously chosen recordings"] as [String?] {
                if let saved { defaults.set(saved, forKey: "recordingRoot") }
                let model = AppModel(preview: false, defaults: defaults, storage: storage)
                let expected = saved ?? storage.music.appendingPathComponent("Switchboard/Recordings").path
                try require(
                    model.recordingRoot.path == expected && !model.needsRecordingFolderSetup,
                    "Update changed an existing save folder")
                try require(
                    model.preferredUID == "headphones" && model.language == .korean,
                    "Update changed existing preferences")
                try require(
                    defaults.string(forKey: "recordingRoot") == saved,
                    "Update persisted an unsolicited folder change")
                await model.shutdown()
            }
        }
    }

    private static func waitForFolder(_ model: AppModel) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while model.recordingFolderBusy, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try require(!model.recordingFolderBusy, "Folder preparation did not finish")
    }

    private static func withFreshModel(
        _ operation: @MainActor (AppModel, UserDefaults, AppStorageDirectories) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "com.switchboard.tests.first-run.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let storage = AppStorageDirectories(
            documents: root.appendingPathComponent("Documents"), music: root.appendingPathComponent("Music"),
            applicationSupport: root.appendingPathComponent("Support"))
        let model = AppModel(preview: false, defaults: defaults, storage: storage)
        do { try await operation(model, defaults, storage) } catch {
            await model.shutdown()
            throw error
        }
        await model.shutdown()
    }

    private static func fileOpenWhileOpeningDraft() async throws {
        try await blockedFileOpen(openingDraft: true)
    }

    private static func fileOpenWhileEndingSession() async throws {
        try await blockedFileOpen(openingDraft: false)
    }

    private static func blockedFileOpen(openingDraft: Bool) async throws {
        try await withModel { model, root in
            let previous = try recording(in: root, name: "Previous")
            let requested = try recording(in: root, name: "Requested")
            model.recordings = [previous]
            model.directRecordings = [previous]
            model.selectedRecordingID = previous.id
            model.addedLibraryFolders = [root.appendingPathComponent("Added library", isDirectory: true)]
            model.page = "session"
            let folders = model.libraryFolders
            model.openingDraft = openingDraft
            model.endingSession = !openingDraft

            try require(!model.canOpenSessionFile, "An in-progress session transition permitted file opening")
            model.openSession(at: requested.directory)

            try require(model.selectedRecordingID == previous.id, "A blocked file changed the selection")
            try require(model.selectedItem == previous, "A blocked file replaced the selected recording")
            try require(model.recordings == [previous], "A blocked file was added to the visible library")
            try require(model.directRecordings == [previous], "A blocked file was retained as a direct file")
            try require(model.libraryFolders == folders, "A blocked file changed the library folders")
            try require(model.page == "session", "A blocked file navigated away from the current page")
            try require(model.errorMessage != nil, "A blocked external file did not report the busy state")

            model.openingDraft = false
            model.endingSession = false
            model.errorMessage = nil
            try require(model.canOpenSessionFile, "File opening stayed disabled after the transition")
            model.openSession(at: requested.directory)
            try require(model.errorMessage == nil, "A valid file failed after the transition")
            try require(model.selectedItem == requested, "The deferred file could not be selected afterward")
            try require(model.recordings == [previous, requested], "Successful opening lost a library entry")
            try require(
                model.directRecordings == [previous, requested], "Successful opening lost a direct file")
            try require(model.libraryFolders == folders, "Opening a direct file registered its parent folder")
            try require(model.page == "library", "Successful opening did not navigate to the library")
        }
    }

    private static func closeAndRestoreDraft() async throws {
        try await withModel { model, root in
            let saved = try recording(in: root, name: "Saved")
            let draft = try draft(in: root)
            model.recordings = [saved]
            model.unfinishedSessions = [draft]
            model.selectedRecordingID = draft.manifest.id
            try await model.session.restoreDraft(draft)
            let recoveredBytes = try metadataBytes(in: draft.directory)
            try require(model.session.closed && !model.session.active, "The restored draft was not closed")

            model.closeSessionView()

            try require(
                model.selectedRecordingID == nil, "Closing the selected draft left its stale selection")
            try require(model.session.state == nil && model.session.directory == nil, "The draft stayed open")
            try require(model.recordings == [saved], "Closing a draft changed saved recordings")
            try require(
                try metadataBytes(in: draft.directory) == recoveredBytes,
                "Closing a draft changed its package")
            let retained = try SessionStore(draftRoot: draft.directory.deletingLastPathComponent()).drafts()
            try require(retained.count == 1, "Closing a recovered view lost its retained draft")
            try require(retained[0].manifest.id == draft.manifest.id, "Closing a draft replaced its identity")

            model.selectedRecordingID = retained[0].manifest.id
            try await model.session.restoreDraft(retained[0])
            try require(model.session.state?.id == draft.manifest.id, "The same draft could not be restored")
            try require(
                model.selectedRecordingID == draft.manifest.id, "Restoring the draft lost its selection")
            model.closeSessionView()
        }
    }

    private static func selectSavedFromDraft() async throws {
        try await withModel { model, root in
            let saved = try recording(in: root, name: "Saved")
            let draft = try draft(in: root)
            model.recordings = [saved]
            model.unfinishedSessions = [draft]
            model.selectedRecordingID = draft.manifest.id
            try await model.session.restoreDraft(draft)
            let recoveredBytes = try metadataBytes(in: draft.directory)

            // External opening selects the saved item before navigation dismisses the archived draft.
            model.openSession(at: saved.directory)

            try require(model.errorMessage == nil, "Opening a saved recording from a closed draft failed")
            try require(
                model.selectedRecordingID == saved.id, "Closing the old draft erased the new selection")
            try require(model.selectedItem == saved, "The saved recording's detail no longer has a selection")
            try require(
                model.recordings == [saved], "Opening an existing recording duplicated its library row")
            try require(model.directRecordings == [saved], "The opened recording was not retained")
            try require(model.page == "library", "The saved recording did not open in the library")
            try require(
                model.session.state == nil && model.session.directory == nil, "The old draft stayed open")
            try require(
                try metadataBytes(in: draft.directory) == recoveredBytes,
                "Opening a recording changed the draft")

            let retained = try SessionStore(draftRoot: draft.directory.deletingLastPathComponent()).drafts()
            try require(retained.count == 1, "Selecting a saved recording removed the draft")
            try await model.session.restoreDraft(retained[0])
            model.closeSessionView()
            try require(
                model.selectedItem == saved, "Closing an unrelated restored draft cleared the saved item")
        }
    }

    private static func playbackSourceSelection() async throws {
        try await withModel { model, root in
            let first = try recording(in: root, name: "Source selection")
            let second = try recording(in: root, name: "Other recording")
            model.recordings = [first, second]
            model.selectedRecordingID = first.id
            var errors = 0
            // Cancel before yielding so these requests never reach rendering or an audio device.
            model.playback.play(first, side: .caller) { _ in errors += 1 }
            try require(
                model.playback.source == .caller && model.playback.preparing, "Caller was not selected")
            model.playback.play(first, side: .agent) { _ in errors += 1 }
            try require(model.playback.source == .agent, "The new Agent request retained Caller")
            model.playback.toggle()
            model.playback.seek(4)
            model.playback.refresh()
            try require(model.playback.source == .agent, "Transport updates changed the selected source")
            model.playback.play(first, side: model.playback.source.side) { _ in errors += 1 }
            try require(model.playback.source == .agent, "Repeating Play lost the selected source")
            model.selectedRecordingID = second.id
            try require(model.playback.source == .mix, "A different recording inherited the previous source")
            await model.playback.stopAndWait()
            await Task.yield()
            try require(
                model.playback.source == .mix && !model.playback.preparing && errors == 0,
                "A cancelled request changed source state or reported an error")
        }
    }

    private static func withModel(_ operation: (AppModel, URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let suiteName = "com.switchboard.tests.library-navigation.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw NavigationCheckFailure(description: "Could not create isolated defaults")
        }
        defaults.setVolatileDomain(
            ["recordingRoot": root.appendingPathComponent("Library", isDirectory: true).path],
            forName: suiteName)
        defer { defaults.removeVolatileDomain(forName: suiteName) }
        let model = AppModel(preview: true, defaults: defaults)
        do {
            try await operation(model, root)
        } catch {
            await model.shutdown()
            throw error
        }
        await model.shutdown()
        try require(
            defaults.persistentDomain(forName: suiteName)?.isEmpty ?? true,
            "Preview navigation wrote persistent preferences")
    }

    private static func recording(in root: URL, name: String) throws -> RecordingItem {
        let directory = root.appendingPathComponent(name + ".mihrecording", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        var manifest = RecordingManifest(title: name, owner: .manual)
        manifest.status = .complete
        try manifest.save(to: directory)
        return try RecordingLibrary.item(at: directory)
    }

    private static func draft(in root: URL) throws -> StoredSession {
        let store = SessionStore(draftRoot: root.appendingPathComponent("Drafts", isDirectory: true))
        var state = try SessionState(name: "Archived draft", description: "Navigation fixture")
        try state.start(at: 0)
        let metadata = try SessionManifest(state: state)
        let directory = try store.createDraft(metadata)
        try RecordingManifest(id: state.id, title: state.name, createdAt: metadata.createdAt, owner: .manual)
            .save(to: directory)
        guard let draft = try store.drafts().first else {
            throw NavigationCheckFailure(description: "The temporary draft could not be loaded")
        }
        return draft
    }

    private static func metadataBytes(in directory: URL) throws -> [Data] {
        try [SessionManifest.filename, "manifest.json"].map {
            try Data(contentsOf: directory.appendingPathComponent($0))
        }
    }
}
