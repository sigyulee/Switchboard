import Darwin
import Foundation

struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}
func expect(_ condition: @autoclosure () -> Bool, file: StaticString = #filePath, line: UInt = #line) throws {
    if !condition() { throw CheckFailure(description: "\(file):\(line): expectation failed") }
}
func expectThrows(_ operation: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) throws {
    var threw = false
    do { try operation() } catch { threw = true }
    try expect(threw, file: file, line: line)
}
@main struct Runner {
    static func main() {
        let suite = MonitorPolicyChecks()
        let audio = AudioChecks()
        let waveform = WaveformChecks()
        let validation = RecordingValidationChecks()
        let language = LanguageChecks()
        let checks: [(String, () throws -> Void)] = [
            ("language choice is explicit and persistent", language.firstLaunchRequiresChoiceAndSavesIt),
            (
                "legacy preferences do not grant permissions",
                language.migrationPreservesChoicesWithoutCopyingPermissions
            ),
            ("non-finite audio is rejected", validation.nonFiniteAudioIsRejected),
            ("malformed manifests are rejected", validation.malformedManifestsAreRejected),
            (
                "rejected recording audio remains recoverable",
                validation.rejectedAudioCannotBecomeACompleteRecording
            ),
            ("mono PCM is rejected", validation.monoBuffersAreRejected),
            ("recovery rejects incompatible audio", validation.recoveryRejectsNonCanonicalAudio),
            ("monitor fallback consent", suite.fallbackOnlyWithConsentAndReturnsToPreferred),
            ("SPSC wrap, overflow and packet timestamps", audio.queueWrapAndOverflow),
            ("no stale timeline replay", audio.timelineDoesNotReplayOldSlots),
            ("live waveform source separation and silence", waveform.livePeaksAndSilence),
            ("default-input lease", audio.leaseDoesNotRestoreOverExternalSelection),
            ("CAF, mixed M4A, source WAV, crash recovery", audio.recordingMixAndRecovery),
        ]
        var failures = 0
        for (name, test) in checks {
            do {
                try test()
                print("PASS \(name)")
            } catch {
                failures += 1
                FileHandle.standardError.write(Data("FAIL \(name): \(error)\n".utf8))
            }
        }
        guard failures == 0 else { exit(EXIT_FAILURE) }
        print("\(checks.count) checks passed")
    }
}
