import BridgeCore
import Foundation
import TranscriptKit

struct TranscriptChecks {
    func equivalentLanguagesSkipTranslation() throws {
        let configuration = try TranscriptConfiguration(
            callerLocaleIdentifier: "en_US", agentLocaleIdentifier: "ko-KR", targetLocaleIdentifier: "en-US")
        try expect(configuration.skipsTranslation(for: .caller))
        try expect(!configuration.skipsTranslation(for: .agent))
        try expectThrows {
            _ = try TranscriptConfiguration(
                callerLocaleIdentifier: "", agentLocaleIdentifier: "ko-KR", targetLocaleIdentifier: "en")
        }
    }

    func malformedTranscriptIsRejected() throws {
        var entry = TranscriptEntry(
            side: .caller, startFrame: 0, endFrame: 48_000, original: "Hello", isFinal: true)
        try entry.validate()
        entry.endFrame = -1
        try expectThrows { try entry.validate() }
        entry.endFrame = 48_000
        entry.original = String(repeating: "x", count: 32_769)
        try expectThrows { try entry.validate() }
        try expectThrows { _ = try TranscriptAudioPacket(samples: [0, 0], startFrame: Int64.max) }
        try expectThrows { _ = try TranscriptAudioPacket(samples: [.nan, 0], startFrame: 0) }
    }

    func staleUpdatesAndPartialPersistenceAreRejected() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionID = UUID()
        let journal = try TranscriptJournal(sessionID: sessionID, directory: root)
        let first = await journal.beginGeneration()
        var entry = TranscriptEntry(
            side: .caller, startFrame: 0, endFrame: 48_000, original: "Hel", isFinal: false)
        let partialAccepted = try await journal.upsert(entry, token: first)
        try expect(partialAccepted)
        try expect(
            !FileManager.default.fileExists(atPath: root.appendingPathComponent("transcript.json").path))
        entry.original = "Hello"
        entry.isFinal = true
        let finalAccepted = try await journal.upsert(entry, token: first)
        try expect(finalAccepted)
        let current = await journal.snapshot()
        try expect(current.count == 1 && current[0].id == entry.id && current[0].isFinal)
        let second = await journal.beginGeneration()
        let staleAccepted = try await journal.updateTranslation(
            entryID: entry.id, original: "Hello", translation: "안녕", status: .translated, token: first)
        try expect(!staleAccepted)
        let newAccepted = try await journal.updateTranslation(
            entryID: entry.id, original: "Hello", translation: "안녕하세요", status: .translated, token: second)
        try expect(newAccepted)
        let recovered = try TranscriptJournal(sessionID: sessionID, directory: root)
        let saved = await recovered.snapshot()
        try expect(saved.count == 1 && saved[0].translation == "안녕하세요")
    }

    func exportKeepsSpeakersAndBothLanguages() async throws {
        let journal = try TranscriptJournal(sessionID: UUID(), directory: nil)
        let token = await journal.beginGeneration()
        let caller = TranscriptEntry(
            side: .caller, startFrame: 48_000, endFrame: 96_000, original: "안녕하세요", isFinal: true,
            translation: "Hello", translationStatus: .translated)
        let agent = TranscriptEntry(
            side: .agent, startFrame: 96_000, endFrame: 144_000, original: "Welcome", isFinal: true)
        _ = try await journal.upsert(caller, token: token)
        _ = try await journal.upsert(agent, token: token)
        let exported = await journal.exportText()
        try expect(exported.contains("[00:00:01.000] Caller: 안녕하세요"))
        try expect(exported.contains("Hello") && exported.contains("[00:00:02.000] Agent: Welcome"))
    }

    func boundedAudioAdmissionReportsDroppedTimeline() async throws {
        let feeds = TranscriptFeeds(maximumBufferedPackets: 1, maximumPacketFrames: 2)
        try expect(feeds.append(side: .caller, samples: [1, 1], startFrame: 0))
        try expect(!feeds.append(side: .caller, samples: [2, 2], startFrame: 1))
        try expect(feeds.append(side: .agent, samples: [3, 3], startFrame: 0))
        try expect(!feeds.append(side: .agent, samples: [0, 0], startFrame: Int64.max))
        let gaps = feeds.takeGaps(side: .caller)
        try expect(gaps.count == 1 && gaps[0].startFrame == 1 && gaps[0].endFrame == 2)
        try expect(feeds.droppedPacketCount(side: .caller) == 1)
        feeds.finish()
        try expect(!feeds.append(side: .caller, samples: [0, 0], startFrame: 2))
    }

    func recordedBackpressureIsReleasedByCancellationAndFinish() async throws {
        let feeds = TranscriptFeeds(maximumBufferedPackets: 1, maximumPacketFrames: 2)
        try expect(feeds.append(side: .caller, samples: [1, 1], startFrame: 0))
        let cancelled = Task { await feeds.appendRecorded(side: .caller, samples: [2, 2], startFrame: 1) }
        cancelled.cancel()
        let cancelledAccepted = await cancelled.value
        try expect(!cancelledAccepted)
        let finishing = Task { await feeds.appendRecorded(side: .caller, samples: [3, 3], startFrame: 2) }
        feeds.finish()
        let finishedAccepted = await finishing.value
        try expect(!finishedAccepted)
    }

    func archiveRetainsConfigurationGapsAndInterruptedTranslation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionID = UUID()
        let journal = try TranscriptJournal(sessionID: sessionID, directory: root)
        let configuration = try TranscriptConfiguration(
            callerLocaleIdentifier: "ko-KR", agentLocaleIdentifier: "en-US", targetLocaleIdentifier: "en-US")
        try await journal.setConfiguration(configuration)
        let token = await journal.beginGeneration()
        let pending = TranscriptEntry(
            side: .caller, startFrame: 0, endFrame: 48_000,
            original: "안녕하세요", isFinal: true, translationStatus: .pending)
        _ = try await journal.upsert(pending, token: token)
        let gap = TranscriptGap(
            side: .agent, startFrame: 48_000, endFrame: 96_000, reason: "input queue full")
        let gapAccepted = try await journal.recordGap(gap, token: token)
        try expect(gapAccepted)
        _ = await journal.beginGeneration()
        let stale = try await journal.recordGap(gap, token: token)
        try expect(!stale)
        let recovered = try TranscriptJournal(sessionID: sessionID, directory: root)
        let savedConfiguration = await recovered.configuration()
        let savedGaps = await recovered.gaps()
        let savedEntries = await recovered.snapshot()
        try expect(savedConfiguration == configuration && savedGaps == [gap])
        try expect(savedEntries.count == 1 && savedEntries[0].translationStatus == .interrupted)
        try expect(savedEntries[0].translation == nil)

        let file = root.appendingPathComponent("transcript.json")
        guard var archive = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any],
            var malformedGaps = archive["gaps"] as? [[String: Any]], !malformedGaps.isEmpty
        else { throw CheckFailure(description: "transcript archive is missing its gap array") }
        let original = archive
        malformedGaps[0]["startFrame"] = -1
        archive["gaps"] = malformedGaps
        try JSONSerialization.data(withJSONObject: archive).write(to: file)
        try expectThrows { _ = try TranscriptJournal(sessionID: sessionID, directory: root) }
        archive = original
        archive.removeValue(forKey: "configuration")
        archive.removeValue(forKey: "gaps")
        try JSONSerialization.data(withJSONObject: archive).write(to: file)
        let legacy = try TranscriptJournal(sessionID: sessionID, directory: root)
        let legacyConfiguration = await legacy.configuration()
        let legacyGaps = await legacy.gaps()
        try expect(legacyConfiguration == nil && legacyGaps.isEmpty)
    }
}
