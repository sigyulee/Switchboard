import Darwin
import Foundation

struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}
func expect(_ condition: @autoclosure () throws -> Bool, file: StaticString = #filePath, line: UInt = #line)
    throws
{
    if try !condition() { throw CheckFailure(description: "\(file):\(line): expectation failed") }
}
func expectThrows(_ operation: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) throws {
    var threw = false
    do { try operation() } catch { threw = true }
    try expect(threw, file: file, line: line)
}
@main struct Runner {
    static func main() async {
        let suite = MonitorPolicyChecks()
        let audio = AudioChecks()
        let waveform = WaveformChecks()
        let validation = RecordingValidationChecks()
        let language = LanguageChecks()
        let recorder = RecorderConcurrencyChecks()
        let serialQueue = AsyncSerialQueueChecks()
        let library = LibraryStateChecks()
        let mutations = RecordingLibraryMutationChecks()
        let checks: [(String, () async throws -> Void)] = [
            ("stale rename preserves finalized metadata", mutations.staleRenamePreservesFinalizedMetadata),
            (
                "stale recovery preserves completed archive bytes",
                mutations.staleRecoveryReturnsLatestCompleteArchiveWithoutWriting
            ),
            (
                "library mutations validate latest metadata",
                mutations.mutationsValidateTheLatestPersistedManifest
            ),
            (
                "periodic refresh permits slow library publication",
                library.periodicRefreshLetsASlowScanPublish
            ),
            ("library changes coalesce into one follow-up", library.changesCoalesceIntoOneFollowup),
            (
                "stale library completions preserve new roots and shutdown",
                library.staleCompletionsCannotClearNewRootsOrRestartShutdown
            ),
            (
                "pending recording protects library mutations",
                library.pendingRecordingProtectsFolderAndLibraryActions
            ),
            (
                "pending recording is hidden until attached",
                library.pendingArchiveIsHiddenUntilOwnershipIsKnown
            ),
            (
                "library actions respect archive ownership",
                library.libraryAccessPreservesActiveAndFinalizingOwnership
            ),
            ("queued work permits main actor progress", serialQueue.workDoesNotBlockMainActor),
            ("cancelled queued work does not execute", serialQueue.cancelledQueuedWorkDoesNotExecute),
            ("queued values and errors propagate", serialQueue.valuesAndErrorsReturnToCaller),
            (
                "lifecycle work completes after cancellation",
                serialQueue.lifecycleWorkCompletesAfterCancellation
            ),
            ("finish before start is terminal", recorder.finishBeforeStartClosesTheRecorder),
            ("finished recorder cannot be reused", recorder.aFinishedRecorderCannotStartAnotherArchive),
            ("failed recorder start cannot be retried", recorder.aFailedStartCannotBeRetried),
            ("concurrent recorder starts have one winner", recorder.concurrentStartsCreateExactlyOneArchive),
            (
                "start and finish cannot reopen admission",
                recorder.concurrentStartAndFinishCannotReopenAdmission
            ),
            (
                "finish drains every accepted audio block",
                recorder.concurrentFinishPreservesEveryAcceptedBlock
            ),
            ("empty audio cannot bypass queue bounds", recorder.emptyBlocksCannotBypassTheAdmissionBound),
            ("recorder finish errors remain terminal", recorder.finishFailureIsTerminalAndRetainsItsError),
            (
                "late recorder failure callbacks can reenter",
                recorder.delayedFailureCallbackCanReenterItsRecorder
            ),
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
                try await test()
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
