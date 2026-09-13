import AVFAudio
import BridgeCore
import Foundation
import RecorderKit
import Synchronization

struct RecorderConcurrencyChecks {
    func finishBeforeStartClosesTheRecorder() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = ConversationRecorder()
        try expect(try recorder.finish(durationFrames: 0) == nil)
        try expectStartFailure(recorder, root: root, error: .finished)
        try expect(try recorder.finish(durationFrames: 100) == nil)
        try expect(!recorder.append(side: .caller, samples: [1, 1], frame: 0))
        try expect(!FileManager.default.fileExists(atPath: root.path))
    }

    func aFinishedRecorderCannotStartAnotherArchive() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = ConversationRecorder()
        let directory = try recorder.start(root: root, owner: .manual)
        try expect(recorder.append(side: .caller, samples: [0.25, -0.25], frame: 0))
        try expect(try recorder.finish(durationFrames: 1) == directory)
        let saved = try RecordingManifest.load(from: directory)
        try expectStartFailure(recorder, root: root, error: .finished)
        try expect(try recorder.finish(durationFrames: 200) == directory)
        try expect(recorder.snapshot().manifest == saved)
        try expect(try RecordingManifest.load(from: directory) == saved)
        try expect(try FileManager.default.contentsOfDirectory(atPath: root.path).count == 1)
    }

    func aFailedStartCannotBeRetried() throws {
        let root = temporaryRoot()
        try Data([1]).write(to: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = ConversationRecorder()
        try expectThrows { _ = try recorder.start(root: root, owner: .manual) }
        try FileManager.default.removeItem(at: root)
        try expectStartFailure(recorder, root: root, error: .alreadyStarted)
        try expect(recorder.snapshot().error != nil)
        try expect(!recorder.append(side: .caller, samples: [1, 1], frame: 0))
        try expect(try recorder.finish(durationFrames: 0) == nil)
    }

    func concurrentStartsCreateExactlyOneArchive() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = ConversationRecorder()
        let outcomes = Mutex<[Result<URL, any Error>]>([])
        try concurrently(count: 2) { _ in
            let result = Result { try recorder.start(root: root, owner: .manual) }
            outcomes.withLock { $0.append(result) }
        }
        let results = outcomes.withLock { $0 }
        let directories = results.compactMap { try? $0.get() }
        try expect(directories.count == 1)
        try expect(results.count == 2)
        for case .failure(let error) in results {
            try expect(error as? RecorderLifecycleError == .alreadyStarted)
        }
        try expect(try recorder.finish(durationFrames: 0) == directories.first)
        try expect(try FileManager.default.contentsOfDirectory(atPath: root.path).count == 1)
    }

    func concurrentStartAndFinishCannotReopenAdmission() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        for _ in 0..<32 {
            let recorder = ConversationRecorder()
            let outcomes = Mutex(RaceOutcomes())
            try concurrently(count: 2) { index in
                if index == 0 {
                    let result = Result { try recorder.start(root: root, owner: .manual) }
                    outcomes.withLock { $0.start = result }
                } else {
                    let result = Result { try recorder.finish(durationFrames: 0) }
                    outcomes.withLock { $0.finish = result }
                }
            }
            let result = outcomes.withLock { $0 }
            guard let start = result.start, let finish = result.finish else {
                throw CheckFailure(description: "start/finish did not return")
            }
            let finishedDirectory = try finish.get()
            switch start {
            case .success(let directory): try expect(finishedDirectory == directory)
            case .failure(let error):
                try expect(error as? RecorderLifecycleError == .finished)
                try expect(finishedDirectory == nil)
            }
            try expect(!recorder.append(side: .caller, samples: [1, 1], frame: 0))
            try expect(try recorder.finish(durationFrames: 10) == finishedDirectory)
        }
    }

    func concurrentFinishPreservesEveryAcceptedBlock() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = ConversationRecorder(maximumPendingBytes: 1024)
        let directory = try recorder.start(root: root, owner: .manual)
        try expect(recorder.append(side: .caller, samples: [0.5, -0.5], frame: 0))
        let accepted = Mutex<[AudioSide: Bool]>([:])
        let finished = Mutex<[Result<URL?, any Error>]>([])
        try concurrently(count: 4) { index in
            if index < 2 {
                let side: AudioSide = index == 0 ? .caller : .chrome
                let value: Float = index == 0 ? 0.25 : -0.25
                let appended = recorder.append(
                    side: side, samples: [Float](repeating: value, count: 64), frame: index == 0 ? 1 : 0)
                accepted.withLock { $0[side] = appended }
            } else {
                let result = Result { try recorder.finish(durationFrames: 33) }
                finished.withLock { $0.append(result) }
            }
        }
        let finishResults = finished.withLock { $0 }
        try expect(finishResults.count == 2)
        for result in finishResults { try expect(try result.get() == directory) }
        let manifest = try RecordingManifest.load(from: directory)
        try expect(manifest.durationFrames == 33 && manifest.status == .finalizing)
        let admission = accepted.withLock { $0 }
        try expect(admission[.caller] != nil && admission[.chrome] != nil)
        for side in AudioSide.allCases {
            var expected: [Float] = side == .caller ? [0.5, -0.5] : []
            if admission[side] == true {
                expected += [Float](repeating: side == .caller ? 0.25 : -0.25, count: 64)
            }
            var stored: [Float] = []
            for segment in manifest.segments.filter({ $0.side == side }) {
                let file = try AVAudioFile(
                    forReading: directory.appendingPathComponent(segment.filename),
                    commonFormat: .pcmFormatFloat32, interleaved: true)
                guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 64)
                else {
                    throw CheckFailure(description: "recorded PCM allocation")
                }
                try file.read(into: buffer)
                stored += try PCM.samples(buffer)
            }
            try expect(stored == expected)
        }
        try expect(!recorder.append(side: .caller, samples: [1, 1], frame: 33))
    }

    func emptyBlocksCannotBypassTheAdmissionBound() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = ConversationRecorder(maximumPendingBytes: 8)
        _ = try recorder.start(root: root, owner: .manual)
        try expect(!recorder.append(side: .caller, samples: [], frame: 0))
        try expect(!recorder.append(side: .caller, samples: [1, 1], frame: 0))
        _ = try recorder.finish(durationFrames: 0)
        try expect(recorder.snapshot().manifest?.failureCode == MediaFailure.invalidBuffer.rawValue)
    }

    func finishFailureIsTerminalAndRetainsItsError() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = ConversationRecorder()
        let directory = try recorder.start(root: root, owner: .manual)
        try expect(recorder.append(side: .caller, samples: [0.25, -0.25], frame: 0))
        _ = recorder.snapshot()
        let manifestURL = directory.appendingPathComponent("manifest.json")
        try FileManager.default.removeItem(at: manifestURL)
        try FileManager.default.createDirectory(at: manifestURL, withIntermediateDirectories: false)
        let firstFinish = Result { try recorder.finish(durationFrames: 1) }
        try FileManager.default.removeItem(at: manifestURL)
        let repeatedFinish = Result { try recorder.finish(durationFrames: 1) }
        guard case .failure(let firstError) = firstFinish,
            case .failure(let repeatedError) = repeatedFinish
        else { throw CheckFailure(description: "failed finish did not retain its error") }
        try expect((firstError as NSError).domain == (repeatedError as NSError).domain)
        try expect((firstError as NSError).code == (repeatedError as NSError).code)
        try expect(recorder.snapshot().manifest?.status == .failed)
        try expect(recorder.snapshot().error != nil)
        try expectStartFailure(recorder, root: root, error: .finished)
        try expect(!recorder.append(side: .caller, samples: [1, 1], frame: 1))
    }

    func delayedFailureCallbackCanReenterItsRecorder() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let returned = DispatchSemaphore(value: 0)
        let reference = Mutex<ConversationRecorder?>(nil)
        let outcomes = Mutex(CallbackOutcomes())
        let recorder = ConversationRecorder(maximumPendingBytes: 8) { failure in
            entered.signal()
            guard release.wait(timeout: .now() + 10) == .success,
                let target = reference.withLock({ $0 })
            else {
                returned.signal()
                return
            }
            // Calling these synchronously would deadlock if failure delivery stayed on worker.
            let snapshot = target.snapshot()
            let finish = Result { try target.finish(durationFrames: 2) }
            outcomes.withLock {
                $0.failures.append(failure)
                $0.snapshot = snapshot
                $0.finish = finish
            }
            returned.signal()
        }
        reference.withLock { $0 = recorder }
        defer {
            release.signal()
            reference.withLock { $0 = nil }
        }
        let oldDirectory = try recorder.start(root: root, owner: .manual)
        try expect(!recorder.append(side: .caller, samples: [1, 1, 1, 1], frame: 0))
        try expect(entered.wait(timeout: .now() + 10) == .success)
        for _ in 0..<8 {
            try expect(!recorder.append(side: .caller, samples: [1, 1], frame: 0))
        }
        try expect(try recorder.finish(durationFrames: 2) == oldDirectory)

        let nextRecorder = ConversationRecorder()
        let nextDirectory = try nextRecorder.start(root: root, owner: .manual)
        release.signal()
        try expect(returned.wait(timeout: .now() + 10) == .success)
        let result = outcomes.withLock { $0 }
        try expect(result.failures.count == 1)
        try expect(result.failures.first?.media == .overrun)
        try expect(result.snapshot?.manifest?.status == .failed)
        guard let finish = result.finish else {
            throw CheckFailure(description: "failure callback did not finish its recorder")
        }
        try expect(try finish.get() == oldDirectory)
        try expect(nextRecorder.append(side: .caller, samples: [0.25, -0.25], frame: 0))
        try expect(try nextRecorder.finish(durationFrames: 1) == nextDirectory)
        let saved = try RecordingManifest.load(from: nextDirectory)
        try expect(saved.status == .finalizing && saved.failure == nil)
        try expect(saved.segments.count == 1 && saved.segments[0].frames == 1)
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("recorder-check-\(UUID().uuidString)")
    }

    private func expectStartFailure(
        _ recorder: ConversationRecorder, root: URL, error expected: RecorderLifecycleError
    ) throws {
        do {
            _ = try recorder.start(root: root, owner: .manual)
            throw CheckFailure(description: "a terminal recorder accepted another start")
        } catch let error as RecorderLifecycleError {
            try expect(error == expected)
        }
    }

    // A release gate places all operations at the same API boundary without timing sleeps.
    // Deadlines make a broken lifecycle fail the check instead of hanging the runner.
    private func concurrently(count: Int, operation: @escaping @Sendable (Int) -> Void) throws {
        let ready = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let completed = DispatchGroup()
        let outcomes = Mutex<[Result<Void, CheckFailure>]>([])
        defer { for _ in 0..<count { release.signal() } }
        for index in 0..<count {
            completed.enter()
            DispatchQueue.global().async {
                defer { completed.leave() }
                ready.signal()
                guard release.wait(timeout: .now() + 10) == .success else {
                    outcomes.withLock {
                        $0.append(
                            .failure(CheckFailure(description: "operation \(index) release gate timed out")))
                    }
                    return
                }
                operation(index)
                outcomes.withLock { $0.append(.success(())) }
            }
        }
        for _ in 0..<count { try expect(ready.wait(timeout: .now() + 10) == .success) }
        for _ in 0..<count { release.signal() }
        try expect(completed.wait(timeout: .now() + 10) == .success)
        let results = outcomes.withLock { $0 }
        try expect(results.count == count)
        for result in results { try result.get() }
    }
}

private struct RaceOutcomes: Sendable {
    var start: Result<URL, any Error>?
    var finish: Result<URL?, any Error>?
}

private struct CallbackOutcomes: Sendable {
    var failures: [RecorderFailure] = []
    var snapshot: RecorderSnapshot?
    var finish: Result<URL?, any Error>?
}
