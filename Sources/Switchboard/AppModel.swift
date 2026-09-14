import AppKit
import BridgeCore
import CoreAudio
import CryptoKit
import Foundation
import Observation
import RecorderKit

@MainActor @Observable final class AppModel {
    let preview: Bool
    let microphoneAccess: MicrophoneAccess
    let playback = PlaybackController()
    let session: SessionController
    let transcript: TranscriptController
    let storedProcessing = StoredProcessingController()
    private var sessionStartTask: Task<Void, Never>?
    private var pipeline: AudioPipeline { session.pipeline }
    private let callerRouteObserver = CallerRouteObserver()
    private let lease: DefaultInputLease
    let defaults: UserDefaults
    var language: ApplicationLanguage? {
        didSet { if !preview, let language { language.save(in: defaults) } }
    }
    var textSize: AppTextSize {
        didSet { if !preview { defaults.set(textSize.rawValue, forKey: "interfaceTextSize") } }
    }
    var librarySidebarWidth: Double {
        didSet {
            let width = librarySidebarWidth.isFinite ? min(420, max(280, librarySidebarWidth)) : 320
            if width != librarySidebarWidth { librarySidebarWidth = width }
            if !preview { defaults.set(width, forKey: "librarySidebarWidth") }
        }
    }
    var strings: AppStrings { AppStrings(language: language ?? .english) }
    private var loop: Task<Void, Never>?
    private var draftOpenTask: Task<Void, Never>?
    var openingDraft = false
    private var draftLoadTask: Task<Void, Never>?
    var unfinishedSessions: [StoredSession] = []
    private var libraryLoadTask: Task<Void, Never>?
    private var libraryRefresh = LibraryRefreshState()
    private let libraryWork = AsyncSerialQueue(label: "com.switchboard.main.library", qos: .utility)
    private var refreshIndex = 0
    var devices: [AudioDevice] = []
    var audio = PipelineSnapshot()
    var callerRunning = false
    var agentRunning = false
    var suspended: Bool { session.paused }
    var installing = false
    var stopping: Bool { session.busy }
    var starting: Bool { session.busy || sessionStartTask != nil || openingDraft }
    var pausing: Bool { session.busy }
    var recordingURL: URL? { session.directory }
    var recordings: [RecordingItem] = []
    var selectedRecordingID: UUID? {
        didSet { if oldValue != selectedRecordingID { playback.stop() } }
    }
    var finalizing = Set<URL>()
    var page = "session"
    var recordingSearchRequested = false
    var statusBarRefresh: (() -> Void)?
    var openMainWindow: (() -> Void)?
    var showSetup = false
    var showSettings = false
    var showInputOutputGuide = false
    var driverIssue: OperationIssue?
    var captureAccessIssue: OperationIssue?
    var monitorError: AppFailure?
    var errorMessage: String?
    var exportBusy = false
    var captureAccessRequested: Bool
    private let captureBuildID: String
    var captureRequestInProgress = false
    private var captureRequestTask: Task<Void, Never>?
    var preferredUID: String {
        didSet { if !preview { defaults.set(preferredUID, forKey: "monitorUID") } }
    }
    var speakerFallback: Bool {
        didSet { if !preview { defaults.set(speakerFallback, forKey: "speakerFallback") } }
    }
    var callerVolume = 1.0
    var agentVolume = 1.0
    var recordingRoot: URL
    var needsRecordingFolderSetup: Bool
    var recordingFolderIssue: OperationIssue?
    private var recordingFolderTask: Task<Void, Never>?
    var recordingFolderBusy: Bool { recordingFolderTask != nil }
    var addedLibraryFolders: [URL] = []
    var applications: [ApplicationIdentity] = []
    var routeProfile: RouteProfile?
    var sessionName = ""
    var sessionDescription = ""
    var showEndSession = false
    var endingSession = false
    var masterBusy = false
    private var masterTask: Task<Void, Never>?
    var libraryMutationTask: Task<Void, Never>?
    var sessionSaveTask: Task<Void, Never>?
    var directRecordings: [RecordingItem] = []
    var libraryFolders: [URL] {
        (try? LibraryFolders(defaultRoot: recordingRoot, addedRoots: addedLibraryFolders).roots) ?? [
            recordingRoot
        ]
    }
    var canStartSession: Bool {
        preview
            || (session.state == nil && !starting && !installing && !requiresSetup
                && !needsRecordingFolderSetup && !recordingFolderBusy
                && agentRunning && callerRunning)
    }
    var canOpenSessionFile: Bool { !starting && !endingSession }

    var outputs: [AudioDevice] { devices.filter { $0.physical && $0.output && $0.alive } }
    var callerDevice: AudioDevice? { devices.first { $0.uid == AudioDevices.callerUID && $0.alive } }
    var replyDevice: AudioDevice? { devices.first { $0.uid == AudioDevices.replyUID && $0.alive } }
    var agentInputDevice: AudioDevice? { devices.first { $0.uid == AudioDevices.agentInputUID && $0.alive } }
    var driversReady: Bool { callerDevice != nil && replyDevice != nil && agentInputDevice != nil }
    var requiresSetup: Bool { !driversReady || !microphoneAllowed || !captureAccessRequested }
    var microphoneAllowed: Bool { microphoneAccess.allowed }
    var isRecording: Bool { session.recording }
    var libraryAccess: RecordingLibraryAccess {
        RecordingLibraryAccess(
            preview: preview, starting: starting, recordingDirectory: recordingURL, finalizing: finalizing)
    }
    var canChangeRecordingFolder: Bool {
        libraryAccess.canChangeFolder && !session.active && !recordingFolderBusy
    }
    func canEdit(_ item: RecordingItem) -> Bool { libraryAccess.canEdit(item.directory) }
    func canRecover(_ item: RecordingItem) -> Bool {
        libraryAccess.canRecover(item.directory, status: item.manifest.status)
    }
    func canStartRecovery(_ item: RecordingItem) -> Bool {
        libraryAccess.canRecover(
            item.directory, status: item.manifest.status,
            busy: exportBusy || libraryMutationTask != nil)
    }
    var selectedItem: RecordingItem? { recordings.first { $0.id == selectedRecordingID } }
    var preferredDevice: AudioDevice? { outputs.first { $0.uid == preferredUID } }
    var preferredOutputName: String {
        guard !preferredUID.isEmpty else { return strings(.monitorSelected) }
        return preferredDevice?.name ?? defaults.string(forKey: "monitorName") ?? strings(.monitorSelected)
    }
    var monitorDevice: AudioDevice? {
        preferredDevice ?? (speakerFallback ? outputs.first(where: \.builtIn) : nil)
    }
    var statusTitle: String {
        if installing { return strings(.statusInstalling) }
        if suspended { return strings(.statusPaused) }
        if requiresSetup { return strings(.statusSetup) }
        if !session.active { return strings(.statusReady) }
        return audio.callerReady && audio.agentReady
            ? strings(.statusRoutesReady) : strings(.statusConnecting)
    }

    init(
        preview: Bool, defaults: UserDefaults = .standard,
        storage: AppStorageDirectories = .system
    ) {
        self.preview = preview
        microphoneAccess = MicrophoneAccess(preview: preview)
        self.defaults = defaults
        transcript = TranscriptController(defaults: defaults, preview: preview)
        session = SessionController(
            draftRoot: storage.applicationSupport.appendingPathComponent(
                "Switchboard/Drafts", isDirectory: true))
        lease = DefaultInputLease(defaults: defaults)
        language = ApplicationLanguage.saved(in: defaults)
        textSize =
            defaults.string(forKey: "interfaceTextSize").flatMap(AppTextSize.init(rawValue:)) ?? .larger
        let storedWidth = defaults.double(forKey: "librarySidebarWidth")
        librarySidebarWidth = storedWidth.isFinite && (280...420).contains(storedWidth) ? storedWidth : 320
        preferredUID = defaults.string(forKey: "monitorUID") ?? ""
        speakerFallback = defaults.bool(forKey: "speakerFallback")
        if let executable = Bundle.main.executableURL,
            let data = try? Data(contentsOf: executable, options: .mappedIfSafe)
        {
            captureBuildID = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        } else {
            captureBuildID = "unidentified-build"
        }
        captureAccessRequested = defaults.string(forKey: "captureAccessBuild") == captureBuildID
        let folder = RecordingFolderChoice(
            documentsDirectory: storage.documents, savedPath: defaults.string(forKey: "recordingRoot"),
            // Every previously released installation set this marker on launch.
            previousDefault: defaults.bool(forKey: "legacyPreferencesMigrated")
                ? storage.music.appendingPathComponent("Switchboard/Recordings", isDirectory: true) : nil)
        recordingRoot = folder.url
        needsRecordingFolderSetup = !preview && folder.requiresConfirmation
        addedLibraryFolders = (defaults.stringArray(forKey: "libraryFolders") ?? []).map {
            URL(fileURLWithPath: $0)
        }
        if let data = defaults.data(forKey: "routeProfile"),
            let profile = try? JSONDecoder().decode(RouteProfile.self, from: data),
            (try? profile.validate()) != nil
        {
            routeProfile = profile
        } else {
            let agent =
                ApplicationCatalog.installed("com.google.Chrome")
                ?? (try? ApplicationIdentity(
                    bundleIdentifier: "com.google.Chrome",
                    bundleURL: URL(fileURLWithPath: "/Applications/Google Chrome.app"), name: "Google Chrome"))
            let caller =
                ApplicationCatalog.installed("com.apple.mobilephone")
                ?? (try? ApplicationIdentity(
                    bundleIdentifier: "com.apple.mobilephone",
                    bundleURL: URL(fileURLWithPath: "/System/Applications/Phone.app"), name: "Phone"))
            if let agent, let caller { routeProfile = try? RouteProfile(agent: agent, caller: caller) }
        }
        applications = ApplicationCatalog.choices(
            including: routeProfile.map { [$0.agent, $0.caller] } ?? [])
        if preview { loadPreview() }
    }
    func loadDrafts() {
        guard !preview, draftLoadTask == nil else { return }
        draftLoadTask = Task { [weak self] in
            guard let self else { return }
            defer { draftLoadTask = nil }
            do {
                let drafts = try await session.savedDrafts()
                if !Task.isCancelled {
                    unfinishedSessions = drafts.filter { $0.directory != session.directory }
                }
            } catch { if !Task.isCancelled { errorMessage = strings.error(error) } }
        }
    }
    func openDraft(_ draft: StoredSession) {
        guard !preview, session.state == nil, !session.busy, !starting, !openingDraft else { return }
        openingDraft = true
        transcript.clearForNewSession(id: draft.manifest.id)
        draftOpenTask = Task {
            defer {
                openingDraft = false
                draftOpenTask = nil
            }
            do {
                try await session.restoreDraft(draft)
                guard session.state?.id == draft.manifest.id else { throw SessionStoreError.identityMismatch }
                try await transcript.showArchivedSession(id: draft.manifest.id, directory: draft.directory)
            } catch { errorMessage = strings.error(error) }
        }
    }

    func closeSessionView() {
        let closedID = session.state?.id
        guard !openingDraft, !endingSession, session.dismissClosed() else { return }
        if selectedRecordingID == closedID { selectedRecordingID = nil }
        transcript.clearForNewSession(id: UUID())
        loadDrafts()
    }

    func navigate(to page: String) {
        guard !openingDraft, !endingSession else { return }
        if session.closed { closeSessionView() }
        self.page = page
    }

    func findRecordings() {
        guard language != nil, !showSettings, !showSetup else { return }
        navigate(to: "library")
        recordingSearchRequested = true
    }

    func boot() {
        guard loop == nil, !preview, language != nil, !needsRecordingFolderSetup else { return }
        refresh()
        showSetup = requiresSetup
        loadDrafts()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                guard let self else { return }
                updateAudioSnapshot()
                playback.refresh()
                statusBarRefresh?()
                refreshIndex += 1
                if refreshIndex.isMultiple(of: 10) {
                    refresh()
                    session.checkpoint()
                }
                if let error = storedProcessing.error {
                    errorMessage = strings.error(error)
                    storedProcessing.error = nil
                }
                if let error = session.error {
                    errorMessage = strings.error(error)
                    session.error = nil
                }
                if audio.recordingError != nil && isRecording {
                    errorMessage = audio.recordingError.map { strings.error($0) }
                    await stopRecording()
                }
            }
        }
    }
    func refresh() {
        guard !preview, language != nil else { return }
        microphoneAccess.refresh()
        devices = AudioDevices.all()
        if let profile = routeProfile {
            callerRunning = ApplicationCatalog.isRunning(profile.caller)
            agentRunning = ApplicationCatalog.isRunning(profile.agent)
        } else {
            callerRunning = false
            agentRunning = false
        }
        applications = ApplicationCatalog.choices(
            including: routeProfile.map { [$0.agent, $0.caller] } ?? [])
        if preferredUID.isEmpty, let airPods = outputs.first(where: \.airPods) { preferredUID = airPods.uid }
        if let preferredDevice { defaults.set(preferredDevice.name, forKey: "monitorName") }
        if session.active, driversReady, microphoneAllowed, !installing, let profile = routeProfile {
            do { try lease.maintain(devices: devices) } catch {
                errorMessage = strings.error(error)
                if session.running && !masterBusy { Task { await pause(reason: .routeFailure) } }
                return
            }
            pipeline.configure(
                callerID: callerDevice?.id, agentInputID: agentInputDevice?.id, replyID: replyDevice?.id,
                monitorID: monitorDevice?.id,
                agentTarget: captureAccessRequested
                    ? ApplicationCatalog.audioTarget(for: profile.agent) : nil,
                callerVolume: Float(callerVolume), agentVolume: Float(agentVolume))
            if session.running, !session.busy, !masterBusy, let id = session.state?.id {
                let presence = callerRouteObserver.poll(
                    sessionID: id, application: profile.caller,
                    speakerDeviceID: callerDevice?.id, microphoneDeviceID: replyDevice?.id)
                if !callerRunning || presence == .disconnected {
                    Task { await pause(reason: .callerDisconnected) }
                }
            }
        } else if session.running && !masterBusy && (!driversReady || !microphoneAllowed) {
            Task { await pause(reason: .routeFailure) }
        }
        updateAudioSnapshot()
        reloadLibrary()
    }
    private func updateAudioSnapshot() {
        var latest = pipeline.snapshot()
        // Freshness is checked by the pipeline. Its heartbeat is not visible UI state.
        latest.updatedAt = 0
        if monitorError != latest.monitorError { monitorError = latest.monitorError }
        if latest != audio { audio = latest }
        session.updateElapsed(latest.recordedSeconds)
    }
    func requestMicrophone() {
        guard !preview, language != nil else { return }
        microphoneAccess.request()
    }
    func requestAgentAccess() {
        guard !preview, language != nil, !captureRequestInProgress, let application = routeProfile?.agent
        else { return }
        captureRequestInProgress = true
        captureAccessIssue = nil
        captureRequestTask = Task {
            defer {
                captureRequestInProgress = false
                captureRequestTask = nil
            }
            do {
                try await pipeline.requestCapturePermission(
                    target: ApplicationCatalog.audioTarget(for: application))
                try Task.checkCancellation()
                captureAccessRequested = true
                defaults.set(captureBuildID, forKey: "captureAccessBuild")
            } catch is CancellationError {
            } catch { captureAccessIssue = operationIssue(error, fallback: .errorRequestAudio) }
            if !Task.isCancelled { refresh() }
        }
    }
    func openAudioPrivacy() {
        if let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        {
            NSWorkspace.shared.open(url)
        }
    }
    func openMicrophonePrivacy() {
        if let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        {
            NSWorkspace.shared.open(url)
        }
    }
    func installDrivers(remove: Bool = false) async {
        guard !preview, language != nil, !needsRecordingFolderSetup, !session.active, !installing else {
            return
        }
        installing = true
        driverIssue = nil
        await pause()
        do {
            _ = try await PrivilegedInstaller.run(remove: remove)
            for _ in 0..<8 {
                try await Task.sleep(for: .milliseconds(500))
                devices = AudioDevices.all()
                if driversReady || remove { break }
            }
            if !remove && !driversReady { driverIssue = OperationIssue(message: .errorDevicesMissing) }
        } catch {
            driverIssue = operationIssue(error, fallback: remove ? .setupRemoveFailed : .errorInstallFailed)
        }
        installing = false
        if !remove { refresh() }
    }
    private func operationIssue(_ error: Error, fallback: TextKey) -> OperationIssue {
        if let error = error as? AudioFailure {
            return OperationIssue(
                message: error.operation, details: error.detail ?? "OSStatus: \(error.code)")
        }
        return OperationIssue(message: fallback, details: String(describing: error))
    }
    func pause(reason: SessionPauseReason = .manual, preparingToEnd: Bool = false) async {
        guard !preview else { return }
        if let masterTask { await masterTask.value }
        if session.paused && !preparingToEnd { return }
        masterBusy = true
        let task = Task { [self] in
            defer {
                masterBusy = false
                masterTask = nil
            }
            do {
                if session.active {
                    if preparingToEnd {
                        try await session.prepareToEnd()
                    } else {
                        try await session.pause(reason: reason)
                    }
                    await transcript.stop(session: session, preserveChoice: true)
                } else {
                    await pipeline.shutdownRoutes()
                }
            } catch { errorMessage = strings.error(error) }
            refresh()
        }
        masterTask = task
        await task.value
    }
    func resume() {
        guard !preview, !installing, !endingSession, !masterBusy, !requiresSetup, callerRunning, agentRunning
        else { return }
        masterBusy = true
        masterTask = Task { [self] in
            defer {
                masterBusy = false
                masterTask = nil
            }
            do {
                callerRouteObserver.reset()
                try await session.resume()
                if session.state?.transcription == true { transcript.start(session: session) }
            } catch { errorMessage = strings.error(error) }
            refresh()
        }
    }
    func chooseLanguage(_ language: ApplicationLanguage) {
        let firstChoice = self.language == nil
        self.language = language
        if firstChoice && defaults.string(forKey: "transcriptTargetLanguage") == nil {
            transcript.targetLanguage = language.rawValue
        }
        boot()
    }
    func useRecordingFolder(_ candidate: URL) {
        guard canChangeRecordingFolder else { return }
        recordingFolderIssue = nil
        let previous = recordingRoot
        let preparation = Task.detached(priority: .utility) {
            try RecordingFolderChoice.prepare(candidate)
        }
        recordingFolderTask = Task { [weak self] in
            guard let self else {
                preparation.cancel()
                return
            }
            defer { recordingFolderTask = nil }
            do {
                let folder = try await withTaskCancellationHandler {
                    try await preparation.value
                } onCancel: {
                    preparation.cancel()
                }
                try Task.checkCancellation()
                guard libraryAccess.canChangeFolder, !session.active, recordingRoot == previous else {
                    return
                }
                recordingRoot = folder
                defaults.set(folder.path, forKey: "recordingRoot")
                needsRecordingFolderSetup = false
                reloadLibrary()
                boot()
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled {
                    recordingFolderIssue = OperationIssue(
                        message: .folderUnavailable, details: error.localizedDescription)
                }
            }
        }
    }
    func shutdown() async {
        recordingFolderTask?.cancel()
        await recordingFolderTask?.value
        captureRequestTask?.cancel()
        await captureRequestTask?.value
        loop?.cancel()
        loop = nil
        libraryRefresh.shutdown()
        draftLoadTask?.cancel()
        draftLoadTask = nil
        libraryLoadTask?.cancel()
        libraryLoadTask = nil
        if !preview {
            await draftOpenTask?.value
            await sessionStartTask?.value
            await masterTask?.value
            await sessionSaveTask?.value
            if exportBusy { libraryMutationTask?.cancel() }
            await libraryMutationTask?.value
            await storedProcessing.pause()
            await transcript.finishForSave(session: session)
            await session.preserveOnQuit()
            do { try lease.restore(devices: devices) } catch { errorMessage = strings.error(error) }
        }
        await playback.stopAndWait()
    }

    func startSession() {
        if preview {
            let id = UUID()
            transcript.clearForNewSession(id: id)
            do {
                try session.showPreview(
                    id: id,
                    name: sessionName.isEmpty ? strings(.sessionNew) : sessionName,
                    description: sessionDescription)
            } catch { errorMessage = strings.error(error) }
            return
        }
        guard canStartSession else { return }
        let title = sessionName.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = UUID()
        transcript.clearForNewSession(id: id)
        sessionStartTask = Task {
            defer { sessionStartTask = nil }
            do {
                await storedProcessing.pause()
                try lease.maintain(devices: devices)
                callerRouteObserver.reset()
                try await session.start(
                    id: id,
                    name: title.isEmpty ? Date.now.formatted(date: .abbreviated, time: .shortened) : title,
                    description: sessionDescription)
                refresh()
            } catch {
                let message = strings.error(error)
                do { try lease.restore(devices: devices) } catch {
                    errorMessage = message + "\n" + strings.error(error)
                    return
                }
                errorMessage = message
            }
        }
    }
    func startRecording() {
        guard !preview, session.active else { return }
        Task { do { try await session.setRecording(true) } catch { errorMessage = strings.error(error) } }
    }
    func stopRecording() async {
        guard !preview, session.active else { return }
        do { try await session.setRecording(false) } catch { errorMessage = strings.error(error) }
    }
    func endSession() {
        if preview {
            session.closePreview()
            return
        }
        guard session.directory != nil, !session.busy else { return }
        Task {
            await pause(preparingToEnd: true)
            if errorMessage == nil && (session.paused || session.closed) { showEndSession = true }
        }
    }
    func restoreInput() {
        callerRouteObserver.reset()
        do { try lease.restore(devices: devices) } catch { errorMessage = strings.error(error) }
    }
    func finalize(_ directory: URL) {
        guard !finalizing.contains(directory) else { return }
        finalizing.insert(directory)
        Task {
            do {
                _ = try await Task.detached(priority: .utility) {
                    try RecordingRenderer.finalize(directory: directory)
                }.value
            } catch { errorMessage = strings.error(error) }
            finalizing.remove(directory)
            reloadLibrary(afterChange: true)
        }
    }
    func reloadLibrary(afterChange: Bool = false) {
        guard !preview,
            let request = libraryRefresh.request(root: recordingRoot, afterChange: afterChange)
        else { return }
        libraryLoadTask?.cancel()
        loadLibrary(request)
    }
    private func loadLibrary(_ request: LibraryRefreshState.Request) {
        let roots = libraryFolders
        let direct = directRecordings
        libraryLoadTask = Task { [self] in
            defer {
                // An old root's completion must not clear a newer task or its dirty refresh.
                if libraryRefresh.isCurrent(request) {
                    libraryLoadTask = nil
                    if let next = libraryRefresh.finish(request) { loadLibrary(next) }
                }
            }
            do {
                let result = try await libraryWork.run {
                    (
                        try roots.flatMap { try RecordingLibrary.items(in: $0) },
                        RecordingLibrary.refreshed(direct)
                    )
                }
                guard !Task.isCancelled, libraryRefresh.canPublish(request), request.root == recordingRoot,
                    roots == libraryFolders, direct == directRecordings
                else { return }
                directRecordings = result.1
                var ids = Set<UUID>()
                let visible = (result.0 + result.1).filter { ids.insert($0.id).inserted }.filter {
                    libraryAccess.canDisplay($0.directory, status: $0.manifest.status)
                }
                if recordings != visible { recordings = visible }
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled, libraryRefresh.canPublish(request) {
                    errorMessage = strings.error(error)
                }
            }
        }
    }
    private func loadPreview() {
        devices = [
            AudioDevice(
                id: 1, uid: "preview", name: "AirPods Pro", input: false, output: true,
                transport: kAudioDeviceTransportTypeBluetooth, alive: true),
            AudioDevice(
                id: 2, uid: AudioDevices.callerUID, name: "Caller → Switchboard", input: true, output: true,
                transport: kAudioDeviceTransportTypeVirtual, alive: true),
            AudioDevice(
                id: 3, uid: AudioDevices.replyUID, name: "Agent → Caller", input: true, output: true,
                transport: kAudioDeviceTransportTypeVirtual, alive: true),
        ]
        devices.append(
            AudioDevice(
                id: 4, uid: AudioDevices.agentInputUID, name: "Switchboard → Agent", input: true,
                output: true,
                transport: kAudioDeviceTransportTypeVirtual, alive: true))
        preferredUID = "preview"
        callerRunning = true
        agentRunning = true
        audio = PipelineSnapshot(
            callerReady: true, agentReady: true, monitorReady: true, callerLevel: 0, agentLevel: 0)
    }
}
