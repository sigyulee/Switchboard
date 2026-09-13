import BridgeCore
import Foundation
import Observation
import RecorderKit
import TranscriptKit

@MainActor @Observable final class TranscriptController {
    var callerLanguage: String {
        didSet { if !preview { defaults.set(callerLanguage, forKey: "transcriptCallerLanguage") } }
    }
    var agentLanguage: String {
        didSet { if !preview { defaults.set(agentLanguage, forKey: "transcriptAgentLanguage") } }
    }
    var targetLanguage: String {
        didSet { if !preview { defaults.set(targetLanguage, forKey: "transcriptTargetLanguage") } }
    }
    private(set) var speechLanguages: [String] = []
    private(set) var translationLanguages: [String] = []
    private(set) var states: [AudioSide: TranscriptSideState] = [:]
    private var presentation = TranscriptPresentationState()
    private(set) var entries: [TranscriptEntry] {
        get { presentation.entries }
        set { presentation.entries = newValue }
    }
    private(set) var gaps: [TranscriptGap] {
        get { presentation.gaps }
        set { presentation.gaps = newValue }
    }
    private(set) var busy = false
    private(set) var catchingUp = false
    var showConfiguration: Bool {
        get { presentation.showConfiguration }
        set { presentation.showConfiguration = newValue }
    }
    var panelVisible: Bool {
        get { presentation.panelVisible }
        set { presentation.panelVisible = newValue }
    }
    var error: String? {
        get { presentation.error }
        set { presentation.error = newValue }
    }
    var archivedConfiguration: TranscriptConfiguration? { presentation.archiveConfiguration }
    private let defaults: UserDefaults
    private let preview: Bool
    private let engine = LiveTranscriptEngine()
    private var journal: TranscriptJournal?
    private var journalSessionID: UUID?
    private var operation = UUID()
    private var task: Task<Void, Never>?
    private var stopOperation: Task<Void, Never>?
    private let startupGate = TranscriptStartupGate()
    private var stopRevocation: UUID?
    private var capabilityTask: Task<Void, Never>?
    private var hasStarted = false
    private var handoffErrors: [AudioSide: String] = [:]
    private var readiness = TranscriptReadinessState()
    private var activeToken: TranscriptSessionToken?
    private var activeConfiguration: TranscriptConfiguration?
    private let archiveWork = AsyncSerialQueue(
        label: "com.switchboard.main.transcript-archive", qos: .utility)
    private var archiveLoadTask: Task<TranscriptArchiveSnapshot, any Error>?

    init(defaults: UserDefaults, preview: Bool) {
        self.defaults = defaults
        self.preview = preview
        callerLanguage = defaults.string(forKey: "transcriptCallerLanguage") ?? ""
        agentLanguage = defaults.string(forKey: "transcriptAgentLanguage") ?? ""
        targetLanguage =
            defaults.string(forKey: "transcriptTargetLanguage")
            ?? ApplicationLanguage.saved(in: defaults)?.rawValue ?? "en"
    }

    private var strings: AppStrings {
        AppStrings(language: ApplicationLanguage.saved(in: defaults) ?? .english)
    }

    var configuration: TranscriptConfiguration? {
        try? TranscriptConfiguration(
            callerLocaleIdentifier: callerLanguage, agentLocaleIdentifier: agentLanguage,
            targetLocaleIdentifier: targetLanguage)
    }
    var canStart: Bool {
        readiness.canStart(configuration: configuration, busy: busy, stopping: stopOperation != nil)
    }
    var needsSpeechDownload: Bool { states.values.contains { $0.speech == .downloadRequired } }

    func loadLanguages() async {
        guard speechLanguages.isEmpty else { return }
        async let speech = TranscriptCapabilities.supportedSpeechLocaleIdentifiers()
        async let translation = TranscriptCapabilities.supportedTranslationLanguageIdentifiers()
        speechLanguages = await speech
        translationLanguages = await translation
        refreshCapabilities()
    }

    func refreshCapabilities() {
        capabilityTask?.cancel()
        guard let configuration else {
            states = [:]
            readiness = TranscriptReadinessState()
            return
        }
        capabilityTask = Task { [weak self] in
            let capabilities = await TranscriptCapabilities.check(configuration: configuration)
            guard let self, !Task.isCancelled, self.configuration == configuration else { return }
            readiness.updateCapabilities(capabilities.states, configuration: configuration)
            if activeToken == nil { states = capabilities.states }
        }
    }

    /// Call after the preceding session's accepted work has joined. This never starts or cancels an engine.
    func clearForNewSession(id: UUID) {
        startupGate.invalidate()
        archiveLoadTask?.cancel()
        archiveLoadTask = nil
        presentation.select(sessionID: id)
        operation = UUID()
        journal = nil
        journalSessionID = nil
        activeToken = nil
        activeConfiguration = nil
        hasStarted = false
        handoffErrors = [:]
        states = readiness.installedStates
    }

    /// Read-only saved presentation. No speech, translation, capture, or permission request is started.
    func showArchivedSession(id: UUID, directory: URL) async throws {
        clearForNewSession(id: id)
        let selection = presentation.select(sessionID: id, archived: true)
        let work = archiveWork
        let loading = Task {
            try await work.run { try TranscriptJournal.readArchive(sessionID: id, directory: directory) }
        }
        archiveLoadTask = loading
        defer { if presentation.selection == selection { archiveLoadTask = nil } }
        do {
            let snapshot = try await loading.value
            guard !Task.isCancelled else { return }
            _ = presentation.apply(snapshot, selection: selection)
        } catch {
            guard presentation.selection == selection else { return }
            if error is CancellationError { return }
            throw error
        }
    }

    func downloadSpeech() {
        guard !busy, let configuration else { return }
        busy = true
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                busy = false
                task = nil
                refreshCapabilities()
            }
            do { try await TranscriptCapabilities.installSpeechModels(configuration: configuration) } catch {
                self.error = strings.error(error)
            }
        }
    }

    private func startupContext(session: SessionController) -> TranscriptStartupContext {
        TranscriptStartupContext(
            operation: operation, presentation: presentation.selection, sessionID: session.state?.id)
    }

    func start(session: SessionController) {
        guard !busy, stopOperation == nil, session.running, let id = session.state?.id,
            let directory = session.directory, let configuration
        else {
            showConfiguration = true
            return
        }
        if presentation.sessionID != id { clearForNewSession(id: id) }
        busy = true
        catchingUp = true
        showConfiguration = false
        panelVisible = true
        error = nil
        let operation = UUID()
        self.operation = operation
        handoffErrors = [:]
        let includeEarlier = !hasStarted || journalSessionID != id
        let authorization = startupGate.begin(context: startupContext(session: session))
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.operation == operation {
                    busy = false
                    catchingUp = false
                    task = nil
                }
            }
            let context: @MainActor () -> TranscriptStartupContext = {
                self.startupContext(session: session)
            }
            var historyID: UUID?
            do {
                try startupGate.require(authorization, context: context())
                if journalSessionID != id {
                    let opened = try await startupGate.wait(authorization, context: context) {
                        try await archiveWork.run {
                            try TranscriptJournal(sessionID: id, directory: directory)
                        }
                    }
                    journal = opened
                    journalSessionID = id
                    entries = []
                    gaps = []
                    hasStarted = false
                }
                guard let journal else { return }
                try await startupGate.wait(authorization, context: context) {
                    try await journal.setConfiguration(configuration)
                }
                let token = try await startupGate.wait(authorization, context: context) {
                    await journal.beginGeneration()
                }
                activeToken = token
                activeConfiguration = configuration
                guard
                    try await startupGate.wait(
                        authorization, context: context,
                        operation: {
                            try await journal.prepareCheckpoints(
                                durationFrames: TranscriptLimits.maximumFrame, token: token)
                        })
                else { throw TranscriptFailure.staleSession }
                _ = try await startupGate.wait(authorization, context: context) {
                    try await session.setTranscription(
                        true,
                        authorized: { [weak self] in
                            guard let self else { return false }
                            return self.startupGate.permits(
                                authorization, context: self.startupContext(session: session))
                        })
                }
                try startupGate.require(authorization, context: context())
                let initial = await session.pipeline.beginTranscriptBuffering()
                // Capture ownership before the post-await check so cancellation can still detach it.
                historyID = initial.id
                try startupGate.require(authorization, context: context())
                let feeds = try await startupGate.wait(authorization, context: context) {
                    try await engine.start(
                        configuration: configuration, journal: journal, token: token
                    ) { [weak self] event in
                        await self?.receive(event, operation: operation)
                    }
                }
                hasStarted = true
                var reducer = try TranscriptHandoffReducer(
                    startingAt: includeEarlier ? 0 : initial.beginFrame)
                guard
                    var snapshot = try await startupGate.wait(
                        authorization, context: context,
                        operation: {
                            await session.pipeline.transcriptHistorySnapshot(
                                for: initial.id, acknowledging: reducer.cursors)
                        })
                else { throw CancellationError() }
                var checkpoint: TranscriptReplayCheckpoint?
                var reader: RecordedTranscriptReplay?
                var acknowledgedSteps = 0
                handoff: while true {
                    try startupGate.require(authorization, context: context())
                    for side in snapshot.failedSides where handoffErrors[side] == nil {
                        failHandoff(side, message: strings(.errorTranscriptLimit))
                    }
                    let supported = Set(
                        AudioSide.allCases.filter {
                            states[$0]?.speech == .ready && handoffErrors[$0] == nil
                        })
                    switch try reducer.next(in: snapshot, checkpoint: checkpoint, supportedSides: supported) {
                    case .checkpointRequired:
                        guard
                            let fresh = try await startupGate.wait(
                                authorization, context: context,
                                operation: {
                                    try await session.pipeline.checkpointTranscript(for: initial.id)
                                })
                        else {
                            throw CancellationError()
                        }
                        checkpoint = fresh
                        if let manifest = fresh.manifest, let directory = fresh.directory {
                            reader = try RecordedTranscriptReplay(
                                item: RecordingItem(directory: directory, manifest: manifest))
                        } else {
                            reader = nil
                        }
                    case .step(let step):
                        switch step.source {
                        case .recording, .buffered:
                            let samples: [Float]
                            do {
                                if step.source == .recording {
                                    guard let reader else { throw MediaFailure.invalidBuffer }
                                    samples = try await startupGate.wait(authorization, context: context) {
                                        try await reader.read(
                                            side: step.side, at: step.startFrame,
                                            frames: Int(step.endFrame - step.startFrame))
                                    }
                                } else {
                                    samples = step.samples
                                }
                            } catch is CancellationError { throw CancellationError() } catch {
                                failHandoff(step.side, message: strings.error(error))
                                continue
                            }
                            guard
                                try await startupGate.wait(
                                    authorization, context: context,
                                    operation: {
                                        await feeds.appendRecorded(
                                            side: step.side, samples: samples, startFrame: step.startFrame)
                                    })
                            else {
                                try startupGate.require(authorization, context: context())
                                if states[step.side]?.speech == .ready {
                                    failHandoff(step.side, message: strings(.errorTranscriptInput))
                                }
                                continue
                            }
                        case .gap:
                            let gap = TranscriptGap(
                                side: step.side, startFrame: step.startFrame, endFrame: step.endFrame,
                                reason: "live audio buffer overflow")
                            guard
                                try await startupGate.wait(
                                    authorization, context: context,
                                    operation: {
                                        try await journal.recordGap(gap, token: token)
                                    })
                            else {
                                throw CancellationError()
                            }
                            gaps.append(gap)
                        case .silence: break
                        }
                        try reducer.acknowledge(step)
                        acknowledgedSteps += 1
                        if acknowledgedSteps.isMultiple(of: 16) {
                            guard
                                try await startupGate.wait(
                                    authorization, context: context,
                                    operation: {
                                        await session.pipeline.transcriptHistorySnapshot(
                                            for: initial.id, acknowledging: reducer.cursors)
                                    }) != nil
                            else {
                                throw CancellationError()
                            }
                        }
                    case .complete:
                        switch try await startupGate.wait(
                            authorization, context: context,
                            operation: {
                                await session.pipeline.attachTranscript(
                                    feeds, historyID: initial.id, after: reducer.cursors,
                                    supportedSides: supported)
                            })
                        {
                        case .attached: break handoff
                        case .retry(let current): snapshot = current
                        case .obsolete: throw CancellationError()
                        }
                    }
                }
                entries = try await startupGate.wait(authorization, context: context) {
                    await journal.snapshot()
                }
            } catch is CancellationError {
                if let historyID { await session.pipeline.detachTranscript(historyID: historyID) }
            } catch {
                if let historyID { await session.pipeline.detachTranscript(historyID: historyID) }
                guard startupGate.permits(authorization, context: context()) else { return }
                await engine.cancel()
                guard startupGate.permits(authorization, context: context()) else { return }
                self.error = strings.error(error)
                _ = try? await session.setTranscription(false)
            }
        }
    }

    func stop(session: SessionController, preserveChoice: Bool = false) async {
        if let stopOperation {
            let revocation = stopRevocation
            let sessionID = session.state?.id
            let boundary = preserveChoice ? nil : await applyOff(session: session)
            await stopOperation.value
            if let revocation, let boundary, let sessionID,
                startupGate.isCurrentRevocation(revocation)
            {
                try? await session.reconcileTranscriptionOff(at: boundary, sessionID: sessionID)
            }
            return
        }
        // Revoke before the first suspension; cancelling alone does not revoke accepted queued work.
        let revocation = startupGate.invalidate()
        stopRevocation = revocation
        let pending = task
        pending?.cancel()
        let stop = Task { [self] in
            let selection = presentation.selection
            let sessionID = session.state?.id
            let journal = journal
            let token = activeToken
            await session.pipeline.detachTranscript()
            let boundary: Int64?
            if preserveChoice {
                boundary =
                    session.state?.transcriptionIntervals.last?.endFrame ?? session.state?.durationFrames
            } else {
                boundary = await applyOff(session: session)
            }
            await pending?.value
            if !preserveChoice, let boundary, let sessionID,
                startupGate.isCurrentRevocation(revocation)
            {
                do { try await session.reconcileTranscriptionOff(at: boundary, sessionID: sessionID) } catch {
                    if presentation.selection == selection { self.error = strings.error(error) }
                }
            }
            var recording: RecordingManifest?
            var metadata: SessionManifest?
            if let boundary, let state = session.state, token?.sessionID == state.id {
                do {
                    recording = try await session.pipeline.checkpoint(durationFrames: boundary)?.manifest
                    if recording == nil, let directory = session.directory {
                        recording = try await archiveWork.run { try RecordingManifest.load(from: directory) }
                    }
                    metadata = try SessionManifest(
                        state: state, createdAt: session.createdAt, isDraft: !session.closed)
                } catch {
                    if presentation.selection == selection { self.error = strings.error(error) }
                }
            }
            let completion = await engine.stop()
            if let journal, let token, let delivery = completion.delivery, let recording, let boundary {
                do {
                    guard
                        try await journal.commitLiveDelivery(
                            delivery, completion: completion, recording: recording, session: metadata,
                            throughFrame: min(boundary, recording.durationFrames), token: token)
                    else {
                        throw TranscriptFailure.staleSession
                    }
                } catch {
                    if presentation.selection == selection { self.error = strings.error(error) }
                }
            }
            if let journal, presentation.selection == selection {
                entries = await journal.snapshot()
                gaps = await journal.gaps()
            }
            activeToken = nil
            activeConfiguration = nil
            operation = UUID()
            busy = false
            catchingUp = false
            task = nil
        }
        stopOperation = stop
        await stop.value
        stopOperation = nil
        if stopRevocation == revocation { stopRevocation = nil }
        refreshCapabilities()
    }

    private func applyOff(session: SessionController) async -> Int64? {
        let selection = presentation.selection
        // Repeated OFF joins retain the first applied interval boundary.
        let originalBoundary =
            session.state?.transcription == false
            ? session.state?.transcriptionIntervals.last?.endFrame : nil
        do {
            let applied = try await session.setTranscription(false)
            return originalBoundary ?? applied
        } catch {
            if presentation.selection == selection { self.error = strings.error(error) }
            return originalBoundary
                ?? session.state?.transcriptionIntervals.last?.endFrame ?? session.state?.durationFrames
        }
    }

    func finishForSave(session: SessionController) async {
        await stop(session: session, preserveChoice: true)
    }

    private func failHandoff(_ side: AudioSide, message: String) {
        handoffErrors[side] = message
        var state =
            states[side] ?? TranscriptSideState(side: side, speech: .failed, translation: .unsupported)
        state.speech = .failed
        state.message = message
        states[side] = state
        error = "\(side == .caller ? strings(.roleCaller) : "Agent"): \(message)"
    }

    private func receive(_ event: TranscriptEvent, operation: UUID) {
        guard self.operation == operation else { return }
        switch event {
        case .partial(let entry), .final(let entry), .upsert(let entry):
            if let index = entries.firstIndex(where: { $0.id == entry.id }) {
                entries[index] = entry
            } else {
                entries.append(entry)
            }
        case .gap(let gap): gaps.append(gap)
        case .state(var state):
            if let activeConfiguration {
                readiness.observeRunState(state, configuration: activeConfiguration)
            }
            if let message = handoffErrors[state.side] {
                state.speech = .failed
                state.message = message
            }
            states[state.side] = state
        }
    }
}

private actor RecordedTranscriptReplay {
    private var readers: [AudioSide: RecordingAudioReader]
    init(item: RecordingItem) throws {
        readers = try Dictionary(
            uniqueKeysWithValues: AudioSide.allCases.map {
                ($0, try RecordingAudioReader(item: item, side: $0))
            })
    }
    func read(side: AudioSide, at frame: Int64, frames: Int) throws -> [Float] {
        guard let reader = readers[side] else { throw MediaFailure.invalidBuffer }
        return try reader.read(at: frame, frames: frames)
    }
}
