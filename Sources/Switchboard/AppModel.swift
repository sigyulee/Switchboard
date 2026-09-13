import AVFoundation
import AppKit
import BridgeCore
import CoreAudio
import CryptoKit
import Foundation
import Observation
import RecorderKit

@MainActor @Observable final class AppModel {
    let preview: Bool
    let playback = PlaybackController()
    private let pipeline = AudioPipeline()
    private let lease: DefaultInputLease
    private let defaults: UserDefaults
    var language: ApplicationLanguage? {
        didSet { if !preview, let language { language.save(in: defaults) } }
    }
    var strings: AppStrings { AppStrings(language: language ?? .english) }
    private var loop: Task<Void, Never>?
    private var pauseTask: Task<Void, Never>?
    private var recordingStartTask: Task<Void, Never>?
    private var recordingStopTask: Task<Void, Never>?
    private var libraryLoadTask: Task<Void, Never>?
    private var libraryRefresh = LibraryRefreshState()
    private let libraryWork = AsyncSerialQueue(label: "com.switchboard.main.library", qos: .utility)
    private var refreshIndex = 0
    var devices: [AudioDevice] = []
    var audio = PipelineSnapshot()
    var phoneRunning = false
    var chromeRunning = false
    var suspended = false
    var installing = false
    var stopping = false
    var starting = false
    var pausing = false
    var recordingURL: URL?
    var recordings: [RecordingItem] = []
    var selectedRecordingID: UUID? {
        didSet { if oldValue != selectedRecordingID { playback.stop() } }
    }
    var finalizing = Set<URL>()
    var page = "session"
    var statusBarRefresh: (() -> Void)?
    var openMainWindow: (() -> Void)?
    var showSetup = false
    var showSettings = false
    var errorMessage: String?
    var exportBusy = false
    var captureAccessRequested: Bool
    private let captureBuildID: String
    var captureRequestInProgress = false
    var chromeAudioConfirmed = false
    var preferredUID: String {
        didSet { if !preview { defaults.set(preferredUID, forKey: "monitorUID") } }
    }
    var speakerFallback: Bool {
        didSet { if !preview { defaults.set(speakerFallback, forKey: "speakerFallback") } }
    }
    var callerVolume = 1.0
    var chromeVolume = 1.0
    var recordingRoot: URL

    var outputs: [AudioDevice] { devices.filter { $0.physical && $0.output && $0.alive } }
    var callerDevice: AudioDevice? { devices.first { $0.uid == AudioDevices.callerUID && $0.alive } }
    var replyDevice: AudioDevice? { devices.first { $0.uid == AudioDevices.replyUID && $0.alive } }
    var driversReady: Bool { callerDevice != nil && replyDevice != nil }
    var requiresSetup: Bool { !driversReady || !microphoneAllowed || !captureAccessRequested }
    var microphoneAllowed: Bool { preview || AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }
    var isRecording: Bool { recordingURL != nil }
    var libraryAccess: RecordingLibraryAccess {
        RecordingLibraryAccess(
            preview: preview, starting: starting, recordingDirectory: recordingURL, finalizing: finalizing)
    }
    var canChangeRecordingFolder: Bool { libraryAccess.canChangeFolder }
    func canEdit(_ item: RecordingItem) -> Bool { libraryAccess.canEdit(item.directory) }
    func canRecover(_ item: RecordingItem) -> Bool {
        libraryAccess.canRecover(item.directory, status: item.manifest.status)
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
        if preview { return strings(.statusReady) }
        if installing { return strings(.statusInstalling) }
        if suspended { return strings(.statusPaused) }
        if !driversReady || !microphoneAllowed { return strings(.statusSetup) }
        if !phoneRunning { return strings(.statusPhoneWaiting) }
        if !chromeRunning { return strings(.statusChromeWaiting) }
        return audio.callerReady && audio.chromeReady
            ? strings(.statusRoutesReady) : strings(.statusConnecting)
    }

    init(preview: Bool, defaults: UserDefaults = .standard) {
        self.preview = preview
        self.defaults = defaults
        if !preview { LegacyInstallation.migratePreferences(defaults) }
        lease = DefaultInputLease(defaults: defaults)
        language = ApplicationLanguage.saved(in: defaults)
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
        let music =
            FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music")
        recordingRoot =
            defaults.string(forKey: "recordingRoot").map { URL(fileURLWithPath: $0) }
            ?? music.appendingPathComponent("Switchboard/Recordings")
        if preview { loadPreview() }
    }
    func boot() {
        guard loop == nil, !preview, language != nil else { return }
        refresh()
        showSetup = requiresSetup
        loop = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                guard let self else { return }
                updateAudioSnapshot()
                playback.refresh()
                statusBarRefresh?()
                refreshIndex += 1
                if refreshIndex.isMultiple(of: 10) { refresh() }
                if audio.recordingError != nil && isRecording {
                    errorMessage = audio.recordingError.map { strings.error($0) }
                    await stopRecording()
                }
            }
        }
    }
    func refresh() {
        guard !preview, language != nil else { return }
        devices = AudioDevices.all()
        let apps = NSWorkspace.shared.runningApplications
        let phone = apps.first { $0.bundleIdentifier == "com.apple.mobilephone" }
        phoneRunning = phone != nil
        chromeRunning = apps.contains { $0.bundleIdentifier == "com.google.Chrome" }
        if preferredUID.isEmpty, let airPods = outputs.first(where: \.airPods) { preferredUID = airPods.uid }
        if let preferredDevice { defaults.set(preferredDevice.name, forKey: "monitorName") }
        if !suspended, driversReady, microphoneAllowed, !installing {
            do { try lease.maintain(devices: devices) } catch { errorMessage = strings.error(error) }
            pipeline.configure(
                callerID: callerDevice?.id, replyID: replyDevice?.id,
                monitorID: monitorDevice?.id,
                chromeRunning: chromeRunning && phoneRunning && captureAccessRequested,
                callerVolume: Float(callerVolume), chromeVolume: Float(chromeVolume))
        } else if !suspended && !installing {
            pipeline.configure(callerID: nil, replyID: nil, monitorID: nil, chromeRunning: false)
        }
        updateAudioSnapshot()
        if audio.chromeLevel > 0.0001 { chromeAudioConfirmed = true }
        reloadLibrary()
    }
    private func updateAudioSnapshot() {
        var latest = pipeline.snapshot()
        // Freshness is checked by the pipeline. Its heartbeat is not visible UI state.
        latest.updatedAt = 0
        if latest != audio { audio = latest }
    }
    func requestMicrophone() {
        guard !preview, language != nil else { return }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in Task { @MainActor in self?.refresh() } }
    }
    func requestChromeAccess() {
        guard !preview, language != nil, !captureRequestInProgress else { return }
        captureRequestInProgress = true
        Task {
            do {
                try await pipeline.requestCapturePermission()
                captureAccessRequested = true
                defaults.set(captureBuildID, forKey: "captureAccessBuild")
            } catch { errorMessage = strings.error(error) }
            captureRequestInProgress = false
            refresh()
        }
    }
    func openAudioPrivacy() {
        if let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        {
            NSWorkspace.shared.open(url)
        }
    }
    func installDrivers(remove: Bool = false) async {
        guard !preview, language != nil else { return }
        installing = true
        await pause()
        do {
            _ = try await PrivilegedInstaller.run(remove: remove)
            for _ in 0..<8 {
                try await Task.sleep(for: .milliseconds(500))
                devices = AudioDevices.all()
                if driversReady || remove { break }
            }
            if !remove && !driversReady { errorMessage = strings(.errorDevicesMissing) }
        } catch { errorMessage = strings.error(error) }
        installing = false
        if !remove {
            suspended = false
            refresh()
        }
    }
    func pause() async {
        if let pauseTask {
            await pauseTask.value
            return
        }
        suspended = true
        guard !preview else { return }
        pausing = true
        let task = Task { [self] in
            defer {
                pausing = false
                pauseTask = nil
            }
            await stopRecording()
            await pipeline.shutdownRoutes()
            do { try lease.restore(devices: devices) } catch { errorMessage = strings.error(error) }
            refresh()
        }
        pauseTask = task
        await task.value
    }
    func resume() {
        guard !pausing, !installing else { return }
        suspended = false
        refresh()
    }
    func chooseLanguage(_ language: ApplicationLanguage) {
        self.language = language
        boot()
    }
    func shutdown() async {
        loop?.cancel()
        loop = nil
        libraryRefresh.shutdown()
        libraryLoadTask?.cancel()
        libraryLoadTask = nil
        if !preview { await pause() }
        playback.stop()
    }

    func startRecording() {
        guard !preview, !isRecording, !starting, !stopping, !suspended, !pausing,
            !installing, audio.callerReady, phoneRunning
        else { return }
        starting = true
        let root = recordingRoot
        recordingStartTask = Task { [self] in
            defer {
                starting = false
                recordingStartTask = nil
                reloadLibrary(afterChange: true)
            }
            do {
                recordingURL = try await pipeline.startRecording(root: root, owner: .manual)
            } catch { errorMessage = strings.error(error) }
        }
    }
    func stopRecording() async {
        await recordingStartTask?.value
        if let recordingStopTask {
            await recordingStopTask.value
            return
        }
        guard isRecording else { return }
        stopping = true
        let task = Task { [self] in
            defer {
                recordingURL = nil
                stopping = false
                recordingStopTask = nil
            }
            do {
                let directory = try await pipeline.stopRecording()
                if let directory { finalize(directory) }
            } catch { errorMessage = strings.error(error) }
        }
        recordingStopTask = task
        await task.value
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
        libraryLoadTask = Task { [self] in
            defer {
                // An old root's completion must not clear a newer task or its dirty refresh.
                if libraryRefresh.isCurrent(request) {
                    libraryLoadTask = nil
                    if let next = libraryRefresh.finish(request) { loadLibrary(next) }
                }
            }
            do {
                let items = try await libraryWork.run { try RecordingLibrary.items(in: request.root) }
                guard !Task.isCancelled, libraryRefresh.canPublish(request), request.root == recordingRoot
                else { return }
                let visible = items.filter {
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
                id: 2, uid: AudioDevices.callerUID, name: "Phone → Agent", input: true, output: true,
                transport: kAudioDeviceTransportTypeVirtual, alive: true),
            AudioDevice(
                id: 3, uid: AudioDevices.replyUID, name: "Chrome → Phone", input: true, output: true,
                transport: kAudioDeviceTransportTypeVirtual, alive: true),
        ]
        preferredUID = "preview"
        phoneRunning = true
        chromeRunning = true
        audio = PipelineSnapshot(
            callerReady: true, chromeReady: true, monitorReady: true, callerLevel: 0.08, chromeLevel: 0.002)
    }
}
