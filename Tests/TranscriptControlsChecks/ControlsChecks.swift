// SPDX-License-Identifier: AGPL-3.0-only
import BridgeCore
import Darwin
import Foundation
import TranscriptKit

private struct ControlsCheckFailure: Error, CustomStringConvertible {
    let description: String
}

private func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw ControlsCheckFailure(description: message) }
}

@main @MainActor struct ControlsChecks {
    static func main() async {
        let checks: [(String, @MainActor () async throws -> Void)] = [
            (
                "language changes stop transcription and preserve the session and existing text",
                languageChanges
            ),
            ("Record Only turns transcription off and re-entry requires explicit Start", recordOnly),
            ("reopening configuration supersedes a pending panel dismissal", reopeningDuringStop),
            ("language changes preserve paused recording intent", pausedLanguageChanges),
            ("engine failure summaries separate readable messages from technical details", engineFailures),
            ("translation results update failure, availability and recovery states", translationResults),
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
            "\(checks.count) transcript control checks passed without audio devices or permission requests.")
    }

    private static func languageChanges() async throws {
        try await withModel { model, _ in
            let original = model.transcript.entries
            _ = try await model.session.setTranscription(true)
            model.transcript.setLanguage("ko-KR", for: .caller, session: model.session)
            model.transcript.setLanguage("en-US", for: .agent, session: model.session)
            model.transcript.setLanguage("ja-JP", for: .target, session: model.session)
            try require(model.transcript.changingConfiguration, "language transitions must block Start")
            try require(!model.transcript.canStart, "old readiness must not authorize new languages")
            await model.transcript.finishConfigurationChanges()
            try require(
                !model.session.transcriptionEnabled, "language changes must revoke transcription intent")
            try require(model.session.running && model.session.recording, "recording and relay must stay on")
            try require(model.transcript.entries == original, "existing transcript text changed")
            try require(model.transcript.callerLanguage == "ko-KR", "caller choice lost")
            try require(model.transcript.agentLanguage == "en-US", "agent choice lost")
            try require(model.transcript.targetLanguage == "ja-JP", "latest target choice lost")
            try require(
                model.transcript.showConfiguration && model.transcript.panelVisible, "configuration hidden")
            try require(
                !model.transcript.busy && !model.transcript.isProcessing, "engine unexpectedly restarted")
        }
    }

    private static func recordOnly() async throws {
        try await withModel { model, _ in
            let original = model.transcript.entries
            _ = try await model.session.setTranscription(true)
            model.transcript.recordOnly(session: model.session)
            await model.transcript.finishConfigurationChanges()
            try require(!model.transcript.panelVisible, "Record Only did not hide the panel")
            try require(!model.session.transcriptionEnabled, "Record Only left transcription intent enabled")
            try require(model.session.recording && model.session.running, "Record Only stopped session audio")
            model.setTranscriptionEnabled(true)
            try require(
                model.transcript.panelVisible && model.transcript.showConfiguration, "re-entry missing")
            try require(
                !model.session.transcriptionEnabled && !model.transcript.busy, "re-entry auto-started")
            try require(model.transcript.entries == original, "Record Only erased saved text")
        }
    }

    private static func reopeningDuringStop() async throws {
        try await withModel { model, _ in
            _ = try await model.session.setTranscription(true)
            model.transcript.recordOnly(session: model.session)
            model.transcript.openConfiguration()
            await model.transcript.finishConfigurationChanges()
            try require(
                model.transcript.panelVisible && model.transcript.showConfiguration, "late dismissal won")
            try require(!model.session.transcriptionEnabled, "pending OFF did not finish")
        }
    }

    private static func pausedLanguageChanges() async throws {
        try await withModel { model, _ in
            _ = try await model.session.setTranscription(true)
            try await model.session.pause()
            model.transcript.setLanguage("de-DE", for: .caller, session: model.session)
            await model.transcript.finishConfigurationChanges()
            try require(
                model.session.paused && !model.session.running, "changing language resumed the session")
            try require(model.session.audioRecordingEnabled, "paused recording intent was lost")
            try require(!model.session.transcriptionEnabled, "paused transcription choice did not turn off")
        }
    }

    private static func engineFailures() async throws {
        let states: [AudioSide: TranscriptSideState] = [
            .caller: TranscriptSideState(
                side: .caller, speech: .failed, translation: .notNeeded, message: "expectedString: 123"),
            .agent: TranscriptSideState(side: .agent, speech: .ready, translation: .resourceLimit),
        ]
        let speech = TranscriptEnginePresentation(kind: .speech, states: states)
        try require(speech.state == .failed && speech.issue == .transcriptSpeechFailure, "speech summary")
        try require(speech.details == "expectedString: 123", "technical details should remain inspectable")
        let translation = TranscriptEnginePresentation(kind: .translation, states: states)
        try require(
            translation.state == .resourceLimit && translation.issue == .transcriptTranslationFailure,
            "translation resource failure must have its own readable message")
        try require(translation.details == nil, "unrelated speech error leaked into translation details")
        let unavailable = TranscriptEnginePresentation(
            kind: .translation,
            states: [.caller: TranscriptSideState(side: .caller, speech: .ready, translation: .unsupported)])
        try require(
            unavailable.state == .unsupported && unavailable.issue == nil, "unsupported mislabeled failure")
        let sameLanguage = TranscriptEnginePresentation(
            kind: .translation,
            states: [.caller: TranscriptSideState(side: .caller, speech: .ready, translation: .notNeeded)])
        try require(sameLanguage.state == .notNeeded && sameLanguage.issue == nil, "same-language mislabeled")
    }

    private static func translationResults() async throws {
        for (input, output) in [
            (TranscriptTranslationStatus.failed, TranscriptModelState.failed),
            (.dropped, .resourceLimit), (.unsupported, .unsupported),
            (.downloadRequired, .downloadRequired), (.translated, .ready),
        ] {
            try require(
                TranscriptEnginePresentation.translationState(for: input) == output, "\(input) state lost")
        }
        try require(
            TranscriptEnginePresentation.translationState(for: .pending) == nil, "pending cleared failure")
    }

    private static func withModel(_ operation: (AppModel, URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "com.switchboard.tests.transcript-controls.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            throw ControlsCheckFailure(description: "Could not create isolated preferences")
        }
        defaults.setVolatileDomain(
            ["recordingRoot": root.appendingPathComponent("Library").path], forName: suite)
        defer { defaults.removeVolatileDomain(forName: suite) }
        let model = AppModel(preview: true, defaults: defaults)
        let id = UUID()
        try model.session.showPreview(id: id, name: "Transcript control fixture", description: "")
        let archive = root.appendingPathComponent("Transcript")
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: false)
        let journal = try TranscriptJournal(sessionID: id, directory: archive)
        let token = await journal.beginGeneration()
        _ = try await journal.upsert(
            TranscriptEntry(
                side: .caller, startFrame: 0, endFrame: 1, original: "Existing text", isFinal: true),
            token: token)
        try await model.transcript.showArchivedSession(id: id, directory: archive)
        do {
            try await operation(model, root)
        } catch {
            await model.transcript.finishConfigurationChanges()
            await model.shutdown()
            throw error
        }
        await model.transcript.finishConfigurationChanges()
        await model.shutdown()
        try require(defaults.persistentDomain(forName: suite)?.isEmpty ?? true, "preview wrote preferences")
    }
}
