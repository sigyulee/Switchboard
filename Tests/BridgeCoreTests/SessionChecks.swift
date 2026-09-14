import BridgeCore
import Foundation
import RecorderKit

struct SessionChecks {
    func masterPausePreservesDesiredTogglesAndSilentTime() throws {
        var state = try SessionState(name: "A session", description: "Two participants")
        let id = state.id
        try expect(state.lifecycle == .idle && state.audioRecording && !state.transcription)
        try state.start(at: 0)
        try state.setTranscription(true, at: 48_000)
        try state.pause(at: 96_000, reason: .manual)
        try state.advance(to: 144_000)
        try expect(state.durationFrames == 144_000)
        try expect(state.audioRecording && state.transcription)
        try expect(!state.effectiveAudioRecording && !state.effectiveTranscription)
        try state.resume(at: 192_000)
        try state.end(at: 240_000)
        try expect(state.id == id && state.durationFrames == 240_000)
        try expect(state.recordingIntervals == [interval(0, 96_000), interval(192_000, 48_000)])
        try expect(state.transcriptionIntervals == [interval(48_000, 48_000), interval(192_000, 48_000)])
        try expect(!state.effectiveAudioRecording && !state.effectiveTranscription)
    }

    func recordingAndTranscriptionIntervalsAreIndependent() throws {
        var state = try SessionState(name: "Independent controls")
        try state.start(at: 0)
        try state.setTranscription(true, at: 10)
        try state.setAudioRecording(false, at: 20)
        try state.advance(to: 30)
        try expect(!state.effectiveAudioRecording && state.effectiveTranscription)
        try state.pause(at: 40, reason: .callerDisconnected)
        try state.setAudioRecording(true, at: 50)
        try state.setTranscription(false, at: 60)
        try expect(state.pauseReason == .callerDisconnected)
        try state.resume(at: 70)
        try expect(state.effectiveAudioRecording && !state.effectiveTranscription)
        try state.end(at: 80)
        try expect(state.recordingIntervals == [interval(0, 20), interval(70, 10)])
        try expect(state.transcriptionIntervals == [interval(10, 30)])
    }

    func transitionsAreIdempotentAndEndedStateIsImmutable() throws {
        var state = try SessionState(name: "Transitions")
        try expectThrows { try state.pause(at: 0, reason: .manual) }
        try expectThrows { try state.resume(at: 0) }
        try expectThrows { try state.end(at: 0) }
        try state.start(at: 0)
        try state.start(at: 0)
        try state.pause(at: 10, reason: .routeFailure)
        let paused = state
        try state.pause(at: 10, reason: .manual)
        try expect(state == paused)
        try state.resume(at: 20)
        try state.resume(at: 20)
        try state.end(at: 30)
        let ended = state
        try state.end(at: 30)
        try expectThrows { try state.start(at: 40) }
        try expectThrows { try state.resume(at: 40) }
        try expectThrows { try state.advance(to: 40) }
        try expectThrows { try state.setAudioRecording(false, at: 40) }
        try expectThrows { try state.setTranscription(true, at: 40) }
        try expect(state == ended)
    }

    func invalidAndOverflowFramesLeaveStateUnchanged() throws {
        var state = try SessionState(name: "Bounds")
        try expectThrows { try state.start(at: -1) }
        try state.start(at: 0)
        try state.advance(to: 20)
        let before = state
        try expectThrows { try state.advance(to: -1) }
        try expectThrows { try state.advance(to: 19) }
        try expectThrows { try state.advance(by: -1) }
        try expectThrows { try state.advance(by: Int64.max) }
        try expectThrows { try state.setTranscription(true, at: 19) }
        try expect(state == before)
        try expectThrows { _ = try SessionInterval(startFrame: Int64.max, frames: 1) }
        try expectThrows { _ = try SessionInterval(startFrame: 0, frames: 0) }
    }

    func sessionMetadataRejectsCorruptionAndUnboundedValues() throws {
        try expectThrows { _ = try SessionState(name: " \n ") }
        try expectThrows { _ = try SessionState(name: String(repeating: "x", count: 513)) }
        try expectThrows {
            _ = try SessionState(name: "Name", description: String(repeating: "x", count: 16_385))
        }
        var state = try SessionState(name: "Metadata")
        try state.start(at: 0)
        try state.advance(to: 30)
        try expectThrows {
            _ = try SessionManifest(state: state, createdAt: Date(timeIntervalSinceReferenceDate: .nan))
        }
        try expectThrows { _ = try SessionManifest(state: state, isDraft: false) }
        let manifest = try SessionManifest(state: state)
        let encoded = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(SessionManifest.self, from: encoded)
        try expect(decoded == manifest)
        var object = try jsonObject(encoded)
        object["version"] = 99
        try expectInvalidManifest(object)
        object = try jsonObject(encoded)
        var session = object["state"] as! [String: Any]
        session["recordingIntervals"] = [
            ["startFrame": 0, "frames": 20], ["startFrame": 10, "frames": 10],
        ]
        object["state"] = session
        try expectInvalidManifest(object)
        session["recordingIntervals"] = [["startFrame": 20, "frames": 20]]
        object["state"] = session
        try expectInvalidManifest(object)
        session["recordingIntervals"] = []
        session["pauseReason"] = "manual"
        object["state"] = session
        try expectInvalidManifest(object)
    }

    func libraryFoldersKeepOnlyDefaultAndExplicitRoots() throws {
        let root = temporaryRoot()
        let first = root.appendingPathComponent("default")
        let manual = root.appendingPathComponent("manual")
        let next = root.appendingPathComponent("new-default")
        let arbitrarySave = root.appendingPathComponent("elsewhere")
        var folders = try LibraryFolders(defaultRoot: first, addedRoots: [manual, manual])
        try expect(folders.roots.count == 2)
        try folders.add(manual.appendingPathComponent("."))
        try expect(folders.roots.count == 2)
        try folders.setDefaultRoot(next)
        try expect(folders.contains(next) && folders.contains(manual))
        try expect(!folders.contains(first) && !folders.contains(arbitrarySave))
        try folders.removeAdded(manual)
        try expect(folders.roots == [folders.defaultRoot])
        try expectThrows { try folders.add(URL(string: "https://example.com/recordings")!) }
        let decoded = try JSONDecoder().decode(LibraryFolders.self, from: JSONEncoder().encode(folders))
        try expect(decoded == folders)
    }

    func draftCreationAndAtomicMetadataUpdatePreserveAudio() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(draftRoot: root)
        var state = try SessionState(name: "Draft", description: "Notes")
        try state.start(at: 0)
        let manifest = try SessionManifest(state: state)
        let directory = try store.createDraft(manifest)
        try expect(directory.pathExtension == "switchboard")
        try expect(Set(FileManager.default.contentsOfDirectory(atPath: directory.path)) == ["session.json"])
        let mode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as! Int
        try expect(mode & 0o777 == 0o700)
        let audio = Data("legacy manifest bytes are separately owned".utf8)
        try audio.write(to: directory.appendingPathComponent("manifest.json"))
        try state.advance(to: 48_000)
        let updated = try SessionManifest(state: state, createdAt: manifest.createdAt)
        try store.update(updated, at: directory)
        try expect(store.load(at: directory) == updated)
        try expectThrows { try store.update(manifest, at: directory) }
        try expect(store.load(at: directory) == updated)
        try expect(Data(contentsOf: directory.appendingPathComponent("manifest.json")) == audio)
        try expect(store.drafts().map(\.directory) == [directory])
        let another = try SessionManifest(state: SessionState(name: "Different identity"))
        try expectThrows { try store.update(another, at: directory) }
        try expect(store.load(at: directory) == updated)
    }

    func successfulPublishMovesClosedPackageWithoutRegisteringItsParent() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let drafts = root.appendingPathComponent("drafts")
        let saved = root.appendingPathComponent("saved")
        try FileManager.default.createDirectory(at: saved, withIntermediateDirectories: true)
        let store = SessionStore(draftRoot: drafts)
        var state = try SessionState(name: "Saved session", description: "Retained description")
        try state.start(at: 0)
        let draft = try SessionManifest(state: state)
        let directory = try store.createDraft(draft)
        let payload = Data([1, 2, 3, 4])
        try payload.write(to: directory.appendingPathComponent("source.caf"))
        try state.end(at: 48_000)
        let complete = try SessionManifest(state: state, createdAt: draft.createdAt, isDraft: false)
        let destination = saved.appendingPathComponent("Custom name.switchboard")
        let folders = try LibraryFolders(defaultRoot: drafts)
        let result = try store.publishClosedDraft(at: directory, to: destination, manifest: complete)
        try expect(
            result.directory.resolvingSymlinksInPath().path
                == destination.standardizedFileURL.resolvingSymlinksInPath().path)
        try expect(result.retainedDraft == nil)
        try expect(!FileManager.default.fileExists(atPath: directory.path))
        try expect(store.load(at: destination) == complete)
        try expect(Data(contentsOf: destination.appendingPathComponent("source.caf")) == payload)
        try expect(!folders.contains(saved))
        try expect(store.packages(in: saved).map(\.manifest) == [complete])
    }

    func destinationCollisionAndFailedPublishPreserveDraft() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(draftRoot: root.appendingPathComponent("drafts"))
        var state = try SessionState(name: "Retain me")
        try state.start(at: 0)
        let draft = try SessionManifest(state: state)
        let directory = try store.createDraft(draft)
        let sourceBytes = try Data(contentsOf: directory.appendingPathComponent("session.json"))
        try state.end(at: 10)
        let complete = try SessionManifest(state: state, createdAt: draft.createdAt, isDraft: false)
        let destination = root.appendingPathComponent("existing.switchboard")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let sentinel = Data("existing user data".utf8)
        try sentinel.write(to: destination.appendingPathComponent("keep.txt"))
        try expectThrows {
            _ = try store.publishClosedDraft(at: directory, to: destination, manifest: complete)
        }
        try expect(Data(contentsOf: destination.appendingPathComponent("keep.txt")) == sentinel)
        let blockingFile = root.appendingPathComponent("not-a-directory")
        try sentinel.write(to: blockingFile)
        try expectThrows {
            _ = try store.publishClosedDraft(
                at: directory, to: blockingFile.appendingPathComponent("result.switchboard"),
                manifest: complete)
        }
        try expect(Data(contentsOf: directory.appendingPathComponent("session.json")) == sourceBytes)
        try expect(store.load(at: directory) == draft)
        try expect(
            !FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".session-") }
        )
    }

    func corruptAndSymlinkPackagesAreRejectedWithoutFollowingLinks() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(draftRoot: root)
        let manifest = try SessionManifest(state: SessionState(name: "Paths"))
        let directory = try store.createDraft(manifest)
        let link = root.appendingPathComponent("link.switchboard")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory)
        try expectThrows { _ = try store.load(at: link) }
        let metadata = directory.appendingPathComponent("session.json")
        let original = try Data(contentsOf: metadata)
        let external = root.appendingPathComponent("outside.json")
        let encoded = try JSONEncoder().encode(manifest)
        try encoded.write(to: external)
        let payloadLink = directory.appendingPathComponent("linked-payload")
        try FileManager.default.createSymbolicLink(at: payloadLink, withDestinationURL: external)
        var ended = manifest.state
        try ended.start(at: 0)
        try ended.end(at: 0)
        let complete = try SessionManifest(state: ended, createdAt: manifest.createdAt, isDraft: false)
        try expectThrows {
            _ = try store.publishClosedDraft(
                at: directory, to: root.appendingPathComponent("saved.switchboard"), manifest: complete)
        }
        try expect(Data(contentsOf: metadata) == original)
        try expect(Data(contentsOf: external) == encoded)
        try FileManager.default.removeItem(at: payloadLink)
        try Data("not JSON".utf8).write(to: metadata)
        try expectThrows { _ = try store.load(at: directory) }
        try FileManager.default.removeItem(at: metadata)
        try FileManager.default.createSymbolicLink(at: metadata, withDestinationURL: external)
        try expectThrows { _ = try store.load(at: directory) }
        try expect(Data(contentsOf: external) == encoded)
        try expectThrows {
            _ = try SessionStore(draftRoot: URL(string: "https://example.com/drafts")!).createDraft(manifest)
        }
    }

    private func interval(_ start: Int64, _ frames: Int64) throws -> SessionInterval {
        try SessionInterval(startFrame: start, frames: frames)
    }

    private func jsonObject(_ data: Data) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    private func expectInvalidManifest(_ object: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        try expectThrows { _ = try JSONDecoder().decode(SessionManifest.self, from: data) }
    }

    func recoveryClosesDraftWithoutInventingCapturedIntervals() throws {
        var state = try SessionState(name: "Interrupted session")
        try state.start(at: 0)
        try state.advance(to: 48_000)
        let recovered = try state.recovered(durationFrames: 96_000)
        try expect(state.lifecycle == .running)
        try expect(recovered.lifecycle == .ended)
        try expect(recovered.durationFrames == 96_000)
        try expect(recovered.recordingIntervals == state.recordingIntervals)
        try expect(!recovered.effectiveAudioRecording && !recovered.effectiveTranscription)
        try expectThrows { _ = try state.recovered(durationFrames: 1) }
        try recovered.validate()
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("session-check-\(UUID().uuidString)")
    }
}
