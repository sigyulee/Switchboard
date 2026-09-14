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
        if await TranscriptReviewChecks.runFIFOProbeIfRequested() { return }
        let suite = MonitorPolicyChecks()
        let audio = AudioChecks()
        let audioReader = AudioReaderChecks()
        let waveform = WaveformChecks()
        let validation = RecordingValidationChecks()
        let gapSummary = RecordingGapSummaryChecks()
        let language = LanguageChecks()
        let recordingFolder = RecordingFolderChecks()
        let recorder = RecorderConcurrencyChecks()
        let serialQueue = AsyncSerialQueueChecks()
        let library = LibraryStateChecks()
        let mutations = RecordingLibraryMutationChecks()
        let rename = RecordingRenameChecks()
        let session = SessionChecks()
        let sessionExport = SessionExportChecks()
        let transcript = TranscriptChecks()
        let sessionAudio = SessionAudioChecks()
        let sessionClock = SessionClockChecks()
        let sessionPaths = SessionStorePathChecks()
        let handoff = TranscriptHandoffChecks()
        let callerRoutes = CallerRouteChecks()
        let replacement = SessionReplacementChecks()
        let stored = StoredTranscriptChecks()
        let directRecordings = DirectRecordingChecks()
        let captureSelection = CaptureSelectionChecks()
        let transcriptReview = TranscriptReviewChecks()
        let checks: [(String, () async throws -> Void)] = [
            (
                "renaming keeps both stored names and preserves session history and payloads",
                rename.renameUpdatesStoredNamesAndPreservesSessionHistoryAndPayloads
            ),
            (
                "renaming rejects invalid names and replaced sources without writing",
                rename.invalidNamesAndReplacedSourcesAreRejectedWithoutWriting
            ),
            (
                "failed second rename metadata replacement restores original bytes",
                rename.secondMetadataReplacementFailureRestoresOriginalBytes
            ),
            (
                "renaming refuses linked metadata without changing its target",
                rename.linkedMetadataIsRejectedWithoutChangingItsTarget
            ),
            (
                "overlapping gaps preserve details without counting missing audio twice",
                gapSummary.overlappingUnorderedGapsPreserveDetailsAndCountUnavailableFramesOnce
            ),
            (
                "gap summaries separate sources and preserve empty metadata",
                gapSummary.eachSourceHasItsOwnSummaryAndMissingMetadataStaysEmpty
            ),
            (
                "adjacent and single frame gaps retain submillisecond durations",
                gapSummary.adjacentAndSingleFrameIntervalsRetainSubMillisecondDurations
            ),
            (
                "gap summaries handle maximum timeline bounds without overflow",
                gapSummary.maximumTimelineBoundsDoNotOverflowOrFillAvailableFrames
            ),
            (
                "gap summaries reject invalid metadata from either source",
                gapSummary.invalidManifestMetadataIsRejectedBeforeSummarizingEitherSource
            ),
            ("recovery waits for export and other library work", mutations.recoveryWaitsForOtherLibraryWork),
            ("saved routes ignore retired confirmation", language.savedRoutesIgnoreRetiredConfirmation),
            (
                "session exports preserve package contents and original",
                sessionExport.packageCopyPreservesAudioTextDescriptionAndOriginal
            ),
            (
                "legacy exports reopen as canonical sessions without losing media or original metadata",
                sessionExport.legacyExportUsesCanonicalFormatAndPreservesKnownMetadataAndMedia
            ),
            (
                "legacy exports retain existing session history",
                sessionExport.legacyExportPreservesExistingSessionHistory
            ),
            (
                "legacy export rejects invalid metadata before copying",
                sessionExport.invalidLegacyMetadataIsRejectedBeforeExport
            ),
            (
                "legacy exports preserve closed statuses and timeline bounds",
                sessionExport.legacyExportKeepsClosedStatusesAndTimelineBounds
            ),
            (
                "session export refuses collisions and source descendants",
                sessionExport.collisionsAndDestinationsInsideSourceAreRefused
            ),
            (
                "session export rejects changed source",
                sessionExport.sourceIdentityAndContentChangesRejectPreparedExport
            ),
            (
                "session export rejects links and unfinished packages",
                sessionExport.symlinkPayloadAndUnfinishedPackagesAreRejected
            ),
            (
                "session export preserves racing destinations",
                sessionExport.commitRacesPreserveTheSourceAndCompetingDestination
            ),
            (
                "cancelled session export removes staging",
                sessionExport.cancelledExportLeavesNoDestinationOrStaging
            ),
            (
                "recovery preserves declared files and discovers orphan audio once",
                validation.recoveryPreservesDeclaredSegmentsAndDiscoversOrphansOnce
            ),
            ("partial file reads preserve nonzero tails", audioReader.partialFileReadsPreserveNonzeroTail),
            (
                "partial reads preserve declared timeline gaps",
                audioReader.partialReadsPreserveDeclaredTimelineGaps
            ),
            (
                "prematurely truncated segments are rejected",
                audioReader.prematurelyTruncatedSegmentIsRejected
            ),
            (
                "cancelled reads do not return audio or invent silence",
                audioReader.cancelledReadDoesNotReturnAudioOrInventSilence
            ),
            (
                "contiguous audio packets ignore clock observation quantization",
                sessionClock.contiguousPacketsIgnoreObservationQuantization
            ),
            (
                "real audio packet loss and pause remain on the timeline",
                sessionClock.genuinePacketLossAndPauseRemainOnTheTimeline
            ),
            (
                "sleep adds silence and rejects packets from the old clock correlation",
                sessionClock.sleepAddsSilenceAndRejectsPacketsFromTheOldCorrelation
            ),
            (
                "preempted clock reads and narrower brackets preserve the audio anchor",
                sessionClock.preemptionAndNarrowerBracketsNeverMoveTheStableAnchor
            ),
            (
                "independent audio sources keep their offsets with one rounding",
                sessionClock.independentSourcesKeepTheirOffsetsAndRoundOnlyOnce
            ),
            (
                "invalid clock readings and arithmetic bounds preserve prior state",
                sessionClock.invalidObservationsAndArithmeticBoundsFailWithoutChangingTheClock
            ),
            (
                "fifo metadata is rejected without blocking",
                transcriptReview.fifoMetadataIsRejectedWithoutBlocking
            ),
            (
                "off revokes startup while journal initialization is suspended",
                transcriptReview.offRevokesStartupWhileJournalInitializationIsSuspended
            ),
            (
                "presentation changes revoke uncancelled startup",
                transcriptReview.presentationChangesRevokeUncancelledStartup
            ),
            (
                "off reconciliation preserves the original boundary and recording",
                transcriptReview.offReconciliationPreservesTheOriginalBoundaryAndRecording
            ),
            (
                "journal rejects a replacement directory without changing either archive",
                transcriptReview.journalRejectsAReplacementDirectoryWithoutChangingEitherArchive
            ),
            (
                "journal rechecks session and audio metadata identity",
                transcriptReview.journalRechecksSessionAndAudioMetadataIdentity
            ),
            (
                "package and ancestor symlinks cannot redirect journal writes",
                transcriptReview.packageAndAncestorSymlinksCannotRedirectJournalWrites
            ),
            (
                "new live gap survives later finals and remains replayable",
                transcriptReview.newLiveGapSurvivesLaterFinalsAndRemainsReplayable
            ),
            (
                "fully delivered silence has no permanent pending work",
                transcriptReview.fullyDeliveredSilenceHasNoPermanentPendingWork
            ),
            (
                "live progress clips at off boundary before drain latency",
                transcriptReview.liveProgressClipsAtOffBoundaryBeforeDrainLatency
            ),
            (
                "only actually enqueued input contributes to delivery evidence",
                transcriptReview.onlyActuallyEnqueuedInputContributesToDeliveryEvidence
            ),
            (
                "successful stop and transient failure keep unchanged languages startable",
                transcriptReview.successfulStopAndTransientFailureKeepUnchangedLanguagesStartable
            ),
            (
                "selecting new session clears old text before any engine start",
                transcriptReview.selectingNewSessionClearsOldTextBeforeAnyEngineStart
            ),
            (
                "archived presentation loads its own text read only and rejects late selection",
                transcriptReview.archivedPresentationLoadsItsOwnTextReadOnlyAndRejectsLateSelection
            ),
            (
                "direct files refresh after rename and removal",
                directRecordings.directRenameAndRemovalReloadWithoutRegisteringItsFolder
            ),
            (
                "direct files reject replacement identities",
                directRecordings.replacedDirectPackageDoesNotBecomeThePreviouslyOpenedSession
            ),
            (
                "matching bundle ID cannot grant another executable root",
                captureSelection.matchingBundleIdentifierCannotGrantAnotherExecutableRoot
            ),
            (
                "default-input lease transfers without losing ownership",
                audio.replacementInputLeasePreservesOwnershipAndExternalChoices
            ),
            (
                "replacement requires explicit authorization",
                replacement.replacementRequiresExplicitAuthorization
            ),
            (
                "authorized swap publishes new and retains the original package",
                replacement.authorizedSwapPublishesNewAndRetainsTheOriginalPackage
            ),
            (
                "changed destination identity rejects the stale authorization",
                replacement.changedDestinationIdentityRejectsTheStaleAuthorization
            ),
            (
                "destination changed after copy is rejected at the coordinated commit",
                replacement.destinationChangedAfterCopyIsRejectedAtTheCoordinatedCommit
            ),
            (
                "changed metadata and symlink targets cannot be authorized away",
                replacement.changedMetadataAndSymlinkTargetsCannotBeAuthorizedAway
            ),
            (
                "invalid copy payload preserves the draft and existing package",
                replacement.invalidCopyPayloadPreservesTheDraftAndExistingPackage
            ),
            (
                "failed backup relocation cannot roll back a successful save",
                replacement.failedBackupRelocationCannotRollBackASuccessfulSave
            ),
            (
                "replacement backup can move to an explicit retention directory",
                replacement.replacementBackupCanMoveToAnExplicitRetentionDirectory
            ),
            (
                "recorded eligibility includes initial backfill and skips explicit off",
                stored.recordedEligibilityIncludesInitialBackfillAndSkipsExplicitOff
            ),
            (
                "session without eligible text is no work and legacy uses only stored segments",
                stored.sessionWithoutEligibleTextIsNoWorkAndLegacyUsesOnlyStoredSegments
            ),
            (
                "old journal fallback becomes explicit before new work",
                stored.oldJournalFallbackBecomesExplicitBeforeNewWork
            ),
            (
                "failed drain never advances that sources checkpoint",
                stored.failedDrainNeverAdvancesThatSourcesCheckpoint
            ),
            (
                "stale and invalid checkpoints cannot replace durable progress",
                stored.staleAndInvalidCheckpointsCannotReplaceDurableProgress
            ),
            (
                "repeated resume preserves finals and exhausted ranges",
                stored.repeatedResumePreservesFinalsAndExhaustedRanges
            ),
            (
                "interrupted translation needs actual translated text",
                stored.interruptedTranslationNeedsActualTranslatedText
            ),
            (
                "recorded eviction requires a newer checkpoint before replay",
                handoff.recordedEvictionRequiresANewerCheckpointBeforeReplay
            ),
            (
                "unrecorded eviction persists only the actual missing interval",
                handoff.unrecordedEvictionPersistsOnlyTheActualMissingInterval
            ),
            (
                "toggled recording unions disk and previously accepted live audio",
                handoff.toggledRecordingUnionsDiskAndPreviouslyAcceptedLiveAudio
            ),
            (
                "eviction between snapshot and acknowledgement does not lose accepted audio",
                handoff.evictionBetweenSnapshotAndAcknowledgementDoesNotLoseAcceptedAudio
            ),
            (
                "atomic attachment retries for new tail and rejects stale history",
                handoff.atomicAttachmentRetriesForNewTailAndRejectsStaleHistory
            ),
            (
                "per speaker frontiers never duplicate or reorder packets",
                handoff.perSpeakerFrontiersNeverDuplicateOrReorderPackets
            ),
            (
                "loss metadata capacity failure is bounded and source local",
                handoff.lossMetadataCapacityFailureIsBoundedAndSourceLocal
            ),
            (
                "arming requires both associated active directions",
                callerRoutes.armingRequiresBothAssociatedActiveDirections
            ),
            (
                "inactive streams and elapsed silence do not disconnect",
                callerRoutes.inactiveStreamsAndElapsedSilenceDoNotDisconnect
            ),
            (
                "actual membership loss must remain observed through debounce",
                callerRoutes.actualMembershipLossMustRemainObservedThroughDebounce
            ),
            ("unknown evidence interrupts loss debounce", callerRoutes.unknownEvidenceInterruptsLossDebounce),
            (
                "verified process disappearance requires prior arming",
                callerRoutes.verifiedProcessDisappearanceRequiresPriorArming
            ),
            (
                "profile session and explicit resume reset reject stale samples",
                callerRoutes.profileSessionAndExplicitResumeResetRejectStaleSamples
            ),
            (
                "invalid clocks and incomplete evidence cannot disconnect",
                callerRoutes.invalidClocksAndIncompleteEvidenceCannotDisconnect
            ),
            (
                "draft recovery closes without inventing capture",
                session.recoveryClosesDraftWithoutInventingCapturedIntervals
            ),
            (
                "executable ownership is limited to the selected bundle",
                sessionAudio.executableOwnershipIsLimitedToTheSelectedBundle
            ),
            (
                "route profiles reject malformed and aliased selections",
                sessionAudio.routeProfilesRejectMalformedAndAliasedSelections
            ),
            (
                "bounded history preserves source and replay boundaries",
                sessionAudio.boundedHistoryPreservesSourceAndReplayBoundaries
            ),
            (
                "malformed history packets cannot consume the budget",
                sessionAudio.malformedHistoryPacketsCannotConsumeTheBudget
            ),
            (
                "session audio shares identity and refuses existing manifest",
                sessionAudio.sessionAudioSharesIdentityAndRefusesExistingManifest
            ),
            (
                "checkpoint seals readable samples without overwriting earlier segments",
                sessionAudio.checkpointSealsReadableSamplesWithoutOverwritingEarlierSegments
            ),
            (
                "discontinuous recording frames render real silence on one timeline",
                sessionAudio.discontinuousRecordingFramesRenderRealSilenceOnOneTimeline
            ),
            (
                "legacy and session libraries require their owned metadata",
                sessionAudio.legacyAndSessionLibrariesRequireTheirOwnedMetadata
            ),
            (
                "public audio reader rejects malformed manifest before reading",
                sessionAudio.publicAudioReaderRejectsMalformedManifestBeforeReading
            ),
            (
                "destination through ancestor alias cannot enter draft",
                sessionPaths.destinationThroughAncestorAliasCannotEnterDraft
            ),
            (
                "ancestor aliases preserve draft ownership and publication",
                sessionPaths.ancestorAliasesPreserveDraftOwnershipAndPublication
            ),
            (
                "canonical ancestors do not follow final package symlink",
                sessionPaths.canonicalAncestorsDoNotFollowFinalPackageSymlink
            ),
            (
                "transcript package preserves languages and gaps",
                transcript.archiveRetainsConfigurationGapsAndInterruptedTranslation
            ),
            (
                "master pause preserves desired toggles and silent time",
                session.masterPausePreservesDesiredTogglesAndSilentTime
            ),
            (
                "recording and transcription intervals are independent",
                session.recordingAndTranscriptionIntervalsAreIndependent
            ),
            (
                "transitions are idempotent and ended state is immutable",
                session.transitionsAreIdempotentAndEndedStateIsImmutable
            ),
            (
                "invalid and overflow frames leave state unchanged",
                session.invalidAndOverflowFramesLeaveStateUnchanged
            ),
            (
                "session metadata rejects corruption and unbounded values",
                session.sessionMetadataRejectsCorruptionAndUnboundedValues
            ),
            (
                "library folders keep only default and explicit roots",
                session.libraryFoldersKeepOnlyDefaultAndExplicitRoots
            ),
            (
                "draft creation and atomic metadata update preserve audio",
                session.draftCreationAndAtomicMetadataUpdatePreserveAudio
            ),
            (
                "successful publish moves closed package without registering its parent",
                session.successfulPublishMovesClosedPackageWithoutRegisteringItsParent
            ),
            (
                "destination collision and failed publish preserve draft",
                session.destinationCollisionAndFailedPublishPreserveDraft
            ),
            (
                "corrupt and symlink packages are rejected without following links",
                session.corruptAndSymlinkPackagesAreRejectedWithoutFollowingLinks
            ),
            ("equivalent languages skip translation", transcript.equivalentLanguagesSkipTranslation),
            ("malformed transcript is rejected", transcript.malformedTranscriptIsRejected),
            (
                "stale updates and partial persistence are rejected",
                transcript.staleUpdatesAndPartialPersistenceAreRejected
            ),
            ("export keeps speakers and both languages", transcript.exportKeepsSpeakersAndBothLanguages),
            (
                "bounded audio admission reports dropped timeline",
                transcript.boundedAudioAdmissionReportsDroppedTimeline
            ),
            (
                "recorded backpressure is released by cancellation and finish",
                transcript.recordedBackpressureIsReleasedByCancellationAndFinish
            ),
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
                "first save folder proposes Documents and requires confirmation",
                recordingFolder.firstChoiceUsesDocumentsAndRequiresConfirmation
            ),
            (
                "saved folders are preserved and invalid values require a choice",
                recordingFolder.savedChoicesArePreservedAndInvalidValuesAskAgain
            ),
            (
                "folder preparation preserves existing files and removes its probe",
                recordingFolder.preparingFolderPreservesContentsAndRemovesProbe
            ),
            (
                "a file cannot be selected as a save folder",
                recordingFolder.anExistingFileCannotBecomeASaveFolder
            ),
            (
                "existing installations retain their previous default folder",
                recordingFolder.previousDefaultIsPreservedWithoutAskingAgain
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
