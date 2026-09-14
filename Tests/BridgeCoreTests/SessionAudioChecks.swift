import AVFAudio
import BridgeCore
import Foundation
import RecorderKit

struct SessionAudioChecks {
    func executableOwnershipIsLimitedToTheSelectedBundle() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = root.appendingPathComponent("Agent.app")
        let executable = bundle.appendingPathComponent("Contents/MacOS/Agent")
        let helper = bundle.appendingPathComponent("Contents/Frameworks/Helper.app/Contents/MacOS/Helper")
        let shared = root.appendingPathComponent(
            "WebKit.framework/XPCServices/WebContent.xpc/Contents/MacOS/WebContent")
        for file in [executable, helper, shared] {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("path ownership fixture".utf8).write(to: file)
        }
        let identity = try ApplicationIdentity(
            bundleIdentifier: "example.agent", bundleURL: bundle, name: "Agent")
        // These assertions test paths only; they do not claim that any fixture is a native process.
        try expect(identity.owns(executableURL: executable))
        try expect(identity.owns(executableURL: helper))
        try expect(
            !identity.owns(
                executableURL: root.appendingPathComponent("Agent.app.sibling.app/Contents/MacOS/Agent")))
        try expect(!identity.owns(executableURL: bundle.appendingPathComponent("ContentsOther/MacOS/Agent")))
        try expect(!identity.owns(executableURL: shared))
        let escaped = bundle.appendingPathComponent("Contents/Frameworks/External")
        try FileManager.default.createSymbolicLink(at: escaped, withDestinationURL: shared)
        try expect(!identity.owns(executableURL: escaped))
        try expect(!identity.owns(executableURL: URL(string: "https://example.com/Agent")!))
    }

    func routeProfilesRejectMalformedAndAliasedSelections() throws {
        let root = temporaryRoot()
        let agent = try ApplicationIdentity(
            bundleIdentifier: "example.agent", bundleURL: root.appendingPathComponent("Agent.app"),
            name: "Agent")
        let caller = try ApplicationIdentity(
            bundleIdentifier: "example.caller", bundleURL: root.appendingPathComponent("Caller.app"),
            name: "Caller")
        let profile = try RouteProfile(agent: agent, caller: caller)
        try profile.validate()
        try expectThrows { _ = try RouteProfile(agent: agent, caller: agent) }
        let alias = try ApplicationIdentity(
            bundleIdentifier: "another.id", bundleURL: agent.bundleURL, name: "Alias")
        try expectThrows { _ = try RouteProfile(agent: agent, caller: alias) }
        let sameID = try ApplicationIdentity(
            bundleIdentifier: agent.id, bundleURL: caller.bundleURL, name: "Duplicate")
        try expectThrows { _ = try RouteProfile(agent: agent, caller: sameID) }
        for identifier in ["", "bad identifier", String(repeating: "x", count: 256)] {
            try expectThrows {
                _ = try ApplicationIdentity(
                    bundleIdentifier: identifier, bundleURL: agent.bundleURL, name: "Bad")
            }
        }
        try expectThrows {
            _ = try ApplicationIdentity(bundleIdentifier: "example.bad", bundleURL: root, name: "Bad")
        }
        try expectThrows {
            _ = try ApplicationIdentity(
                bundleIdentifier: "example.bad", bundleURL: agent.bundleURL, name: " \n ")
        }
        let app = try ApplicationIdentity(
            bundleIdentifier: "com.switchboard.main",
            bundleURL: root.appendingPathComponent("Switchboard.app"), name: "Switchboard")
        try expectThrows { _ = try RouteProfile(agent: app, caller: caller) }

        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as! [String: Any]
        var encodedAgent = object["agent"] as! [String: Any]
        encodedAgent["bundleIdentifier"] = "invalid identity"
        object["agent"] = encodedAgent
        let corrupted = try JSONSerialization.data(withJSONObject: object)
        try expectThrows {
            let decoded = try JSONDecoder().decode(RouteProfile.self, from: corrupted)
            try decoded.validate()
        }
        object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as! [String: Any]
        object["caller"] = object["agent"]
        let duplicate = try JSONSerialization.data(withJSONObject: object)
        try expectThrows {
            let decoded = try JSONDecoder().decode(RouteProfile.self, from: duplicate)
            try decoded.validate()
        }
    }

    func boundedHistoryPreservesSourceAndReplayBoundaries() throws {
        var history = AudioHistory(maximumSamples: 12)
        try history.append(TimedAudio(side: .caller, samples: [1, 1, 2, 2], startFrame: 0))
        try history.append(TimedAudio(side: .agent, samples: [-3, -3, -4, -4], startFrame: 1))
        try history.append(TimedAudio(side: .caller, samples: [5, 5, 6, 6, 7, 7], startFrame: 4))
        try expect(history.droppedThrough[.caller] == 2)
        try expect(history.droppedThrough[.agent] == nil)
        let packets = history.packets(after: 2)
        try expect(packets.count == 2)
        try expect(packets[0].side == .agent && packets[0].startFrame == 2 && packets[0].samples == [-4, -4])
        try expect(
            packets[1].side == .caller && packets[1].startFrame == 4
                && packets[1].samples == [5, 5, 6, 6, 7, 7])
        try expect(history.packets(after: 7).isEmpty)
        try expect(history.packets(after: 6).first?.samples == [7, 7])
    }

    func malformedHistoryPacketsCannotConsumeTheBudget() throws {
        var history = AudioHistory(maximumSamples: 8)
        try history.append(TimedAudio(side: .caller, samples: [0.25, -0.25], startFrame: 0))
        let invalid: [(samples: [Float], start: Int64)] = [
            ([], 1), ([1], 1), ([1, 1], -1), ([1, 1], Int64.max), ([.nan, 0], 1), ([0, .infinity], 1),
        ]
        for packet in invalid {
            try expectThrows {
                _ = try TimedAudio(side: .agent, samples: packet.samples, startFrame: packet.start)
            }
        }
        try history.append(TimedAudio(side: .agent, samples: [Float](repeating: 1, count: 10), startFrame: 1))
        let remaining = history.packets(after: 0)
        try expect(remaining.count == 1 && remaining[0].side == .caller)
        try expect(remaining[0].samples == [0.25, -0.25] && history.droppedThrough.isEmpty)
        try expect(history.packets(after: Int64.min).isEmpty)
        let edge = try TimedAudio(side: .caller, samples: [1, 1], startFrame: Int64.max - 1)
        try expect(edge.endFrame == Int64.max)
        try expect(edge.after(Int64.max) == nil && edge.after(Int64.min) == nil)
    }

    func sessionAudioSharesIdentityAndRefusesExistingManifest() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, session, directory) = try draft(in: root)
        let before = try Data(contentsOf: directory.appendingPathComponent(SessionManifest.filename))
        let audio = RecordingManifest(
            id: session.id, title: session.title, createdAt: session.createdAt, owner: .manual)
        let recorder = ConversationRecorder()
        try expect(recorder.start(directory: directory, manifest: audio) == directory)
        try expect(recorder.append(side: .caller, samples: [0.2, -0.2], frame: 0))
        _ = try recorder.finish(durationFrames: 1)
        let saved = try RecordingManifest.load(from: directory)
        try expect(
            saved.id == session.id && saved.title == session.title && saved.createdAt == session.createdAt)
        try expect(store.load(at: directory) == session)
        try expect(Data(contentsOf: directory.appendingPathComponent(SessionManifest.filename)) == before)
        let audioBytes = try Data(contentsOf: directory.appendingPathComponent("manifest.json"))
        let another = ConversationRecorder()
        try expectThrows { _ = try another.start(directory: directory, manifest: audio) }
        try expect(Data(contentsOf: directory.appendingPathComponent("manifest.json")) == audioBytes)
    }

    func checkpointSealsReadableSamplesWithoutOverwritingEarlierSegments() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (_, session, directory) = try draft(in: root)
        let recorder = ConversationRecorder()
        _ = try recorder.start(
            directory: directory,
            manifest: RecordingManifest(
                id: session.id, title: session.title, createdAt: session.createdAt, owner: .manual))
        defer { _ = try? recorder.finish(durationFrames: 8) }
        let first: [Float] = [0.1, -0.1, 0.2, -0.2, 0.3, -0.3, 0.4, -0.4]
        let agent: [Float] = [-0.3, 0.3, -0.4, 0.4]
        try expect(recorder.append(side: .caller, samples: first, frame: 0))
        try expect(recorder.append(side: .agent, samples: agent, frame: 1))
        let initial = try recorder.checkpoint(durationFrames: 4)
        guard let initialManifest = initial.manifest,
            let sealed = initialManifest.segments.first(where: { $0.side == .caller })
        else { throw CheckFailure(description: "checkpoint did not seal the caller CAF") }
        let sealedURL = directory.appendingPathComponent(sealed.filename)
        let sealedBytes = try Data(contentsOf: sealedURL)
        let initialItem = RecordingItem(directory: directory, manifest: initialManifest)
        try expectSamples(
            RecordingAudioReader(item: initialItem, side: .caller).read(at: 0, frames: 4), first)
        try expectSamples(
            RecordingAudioReader(item: initialItem, side: .agent).read(at: 0, frames: 4),
            [0, 0] + agent + [0, 0])

        let later: [Float] = [-0.5, 0.5, -0.6, 0.6]
        try expect(recorder.append(side: .caller, samples: later, frame: 4))
        try expect(recorder.append(side: .agent, samples: [0.7, -0.7], frame: 4))
        let continued = try recorder.checkpoint(durationFrames: 6)
        let repeated = try recorder.checkpoint(durationFrames: 6)
        try expect(continued.manifest == repeated.manifest)
        try expect(Data(contentsOf: sealedURL) == sealedBytes)
        _ = try recorder.finish(durationFrames: 8)
        let finalManifest = try RecordingManifest.load(from: directory)
        try expect(finalManifest.durationFrames == 8)
        try expect(Set(finalManifest.segments.map(\.filename)).count == finalManifest.segments.count)
        let finalItem = RecordingItem(directory: directory, manifest: finalManifest)
        try expectSamples(
            RecordingAudioReader(item: finalItem, side: .caller).read(at: 0, frames: 8),
            first + later + [0, 0, 0, 0])
        try expectSamples(
            RecordingAudioReader(item: finalItem, side: .agent).read(at: 0, frames: 8),
            [0, 0] + agent + [0, 0, 0.7, -0.7, 0, 0, 0, 0, 0, 0])
    }

    func discontinuousRecordingFramesRenderRealSilenceOnOneTimeline() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, session, directory) = try draft(in: root)
        var state = session.state
        let recorder = ConversationRecorder()
        _ = try recorder.start(
            directory: directory,
            manifest: RecordingManifest(
                id: session.id, title: session.title, createdAt: session.createdAt, owner: .manual))
        for (frame, frames, caller, agent) in [
            (Int64(0), 4, Float(0.25), Float(-0.5)), (8, 2, 0.5, 0.1), (14, 2, -0.25, 0.5),
        ] {
            try expect(
                recorder.append(
                    side: .caller, samples: [Float](repeating: caller, count: frames * 2), frame: frame))
            try expect(
                recorder.append(
                    side: .agent, samples: [Float](repeating: agent, count: frames * 2), frame: frame))
        }
        try state.setAudioRecording(false, at: 4)
        try state.setAudioRecording(true, at: 8)
        try state.pause(at: 10, reason: .manual)
        try state.resume(at: 14)
        try state.end(at: 18)
        _ = try recorder.finish(durationFrames: state.durationFrames)
        let metadata = try SessionManifest(state: state, createdAt: session.createdAt, isDraft: false)
        try store.update(metadata, at: directory)
        let audio = try RecordingManifest.load(from: directory)
        try expect(audio.durationFrames == metadata.durationFrames && audio.durationFrames == 18)
        let item = RecordingItem(directory: directory, manifest: audio)
        let output = root.appendingPathComponent("mix.wav")
        try RecordingRenderer.render(item: item, destination: output)
        let expected: [Float] =
            [Float](repeating: -0.125, count: 8) + [Float](repeating: 0, count: 8)
            + [Float](repeating: 0.3, count: 4) + [Float](repeating: 0, count: 8)
            + [Float](repeating: 0.125, count: 4) + [Float](repeating: 0, count: 4)
        try expectSamples(decodedAudio(output), expected)
    }

    func legacyAndSessionLibrariesRequireTheirOwnedMetadata() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let legacyRecorder = ConversationRecorder()
        let legacy = try legacyRecorder.start(root: root, owner: .manual)
        try expect(legacyRecorder.append(side: .agent, samples: [0.25, -0.25], frame: 0))
        _ = try legacyRecorder.finish(durationFrames: 1)
        let legacyManifest = try RecordingManifest.load(from: legacy)
        let legacyObject =
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: legacy.appendingPathComponent("manifest.json"))) as! [String: Any]
        try expect((legacyObject["segments"] as? [[String: Any]])?.first?["side"] as? String == "chrome")
        try expectSamples(
            RecordingAudioReader(
                item: RecordingItem(directory: legacy, manifest: legacyManifest), side: .agent
            ).read(at: 0, frames: 1), [0.25, -0.25])

        let (store, session, directory) = try draft(in: root)
        let recorder = ConversationRecorder()
        _ = try recorder.start(
            directory: directory,
            manifest: RecordingManifest(
                id: session.id, title: session.title, createdAt: session.createdAt, owner: .manual))
        try expect(recorder.append(side: .caller, samples: [0.5, -0.5], frame: 0))
        _ = try recorder.finish(durationFrames: 1)
        var ended = session.state
        try ended.end(at: 1)
        let complete = try SessionManifest(state: ended, createdAt: session.createdAt, isDraft: false)
        try store.update(complete, at: directory)
        for name in ["unknown.folder", "missing.switchboard", "mismatch.switchboard", "corrupt.switchboard"] {
            let folder = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try legacyManifest.save(to: folder)
            if name == "mismatch.switchboard" {
                try JSONEncoder().encode(complete).write(
                    to: folder.appendingPathComponent(SessionManifest.filename))
            } else if name == "corrupt.switchboard" {
                try Data("broken metadata".utf8).write(
                    to: folder.appendingPathComponent(SessionManifest.filename))
            }
        }
        let corruptLegacy = root.appendingPathComponent("bad.mihrecording")
        try FileManager.default.createDirectory(at: corruptLegacy, withIntermediateDirectories: true)
        try Data("not JSON".utf8).write(to: corruptLegacy.appendingPathComponent("manifest.json"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("link.mihrecording"), withDestinationURL: legacy)
        let listed = try RecordingLibrary.items(in: root)
        try expect(listed.count == 2)
        try expect(Set(listed.map(\.id)) == [legacyManifest.id, session.id])
    }

    func publicAudioReaderRejectsMalformedManifestBeforeReading() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fileURL = root.appendingPathComponent("caller-0.caf")
        var output: AVAudioFile? = try AVAudioFile(
            forWriting: fileURL, settings: PCM.format().settings, commonFormat: .pcmFormatFloat32,
            interleaved: true)
        try output?.write(from: PCM.buffer([0.1, 0.1, 0.2, 0.2, 0.3, 0.3, 0.4, 0.4]))
        output = nil
        var manifest = RecordingManifest(title: "Malformed range", owner: .manual)
        manifest.durationFrames = 1
        manifest.segments = [
            RecordingSegment(side: .caller, filename: fileURL.lastPathComponent, startFrame: 0, frames: 4)
        ]
        try expectThrows {
            let reader = try RecordingAudioReader(
                item: RecordingItem(directory: root, manifest: manifest), side: .caller)
            _ = try reader.read(at: 0, frames: 1)
        }
        manifest.durationFrames = 4
        let reader = try RecordingAudioReader(
            item: RecordingItem(directory: root, manifest: manifest), side: .caller)
        try expectThrows { _ = try reader.read(at: -1, frames: 1) }
        try expectThrows { _ = try reader.read(at: 0, frames: 0) }
        try expectThrows { _ = try reader.read(at: 0, frames: 480_001) }
        try expectThrows { _ = try reader.read(at: Int64.max, frames: 1) }
    }

    private func draft(in root: URL) throws -> (SessionStore, SessionManifest, URL) {
        let store = SessionStore(draftRoot: root)
        var state = try SessionState(name: "Session audio fixture", description: "Decoded audio assertions")
        try state.start(at: 0)
        let session = try SessionManifest(state: state)
        return (store, session, try store.createDraft(session))
    }

    private func decodedAudio(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: true)
        guard file.length > 0, file.length <= 480_000,
            let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat, frameCapacity: UInt32(file.length))
        else { throw CheckFailure(description: "invalid fixture output length") }
        try file.read(into: buffer, frameCount: UInt32(file.length))
        return try PCM.samples(buffer)
    }

    private func expectSamples(_ actual: [Float], _ expected: [Float]) throws {
        try expect(actual.count == expected.count)
        try expect(zip(actual, expected).allSatisfy { abs($0 - $1) < 0.00001 })
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "session-audio-check-\(UUID().uuidString)")
    }
}
