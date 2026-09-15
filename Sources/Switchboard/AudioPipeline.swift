import AudioRealtime
import BridgeCore
import Darwin
import Foundation
import RecorderKit
import Synchronization
import TranscriptKit

struct PipelineSnapshot: Sendable, Equatable {
    var updatedAt: Double = 0
    var callerReady = false
    var agentReady = false
    var monitorReady = false
    var callerLevel: Float = 0
    var agentLevel: Float = 0
    var callerWaveform = [Float](repeating: 0, count: LiveWaveformHistory.count)
    var agentWaveform = [Float](repeating: 0, count: LiveWaveformHistory.count)
    var callerError: AppFailure?
    var agentError: AppFailure?
    var monitorError: AppFailure?
    var recordingError: AppFailure?
    var recordedSeconds: Double = 0
    var droppedFrames: UInt64 = 0
    var agentInputUnderruns: UInt64 = 0
    var replyUnderruns: UInt64 = 0
    var monitorUnderruns: UInt64 = 0
}

// Work owns endpoint lifetimes, session gates and timestamps. Files owns blocking
// recorder operations. The only other mutable state lives inside its named lock.
final class AudioPipeline: @unchecked Sendable {
    private let work = AsyncSerialQueue(label: "com.switchboard.main.audio", qos: .userInteractive)
    private let files = AsyncSerialQueue(label: "com.switchboard.main.audio-files", qos: .utility)
    private let pendingConfiguration = Mutex<PipelineConfiguration?>(nil)
    private let pendingMonitoring = Mutex<MonitoringConfiguration?>(nil)
    private let publication = Mutex(PipelineSnapshot())
    private let permissionWork = DispatchQueue(
        label: "com.switchboard.main.audio-permission", qos: .userInitiated)
    private var permissionRequest: CapturePermissionRequest?
    private var permissionGeneration: UInt64 = 0
    private var timer: DispatchSourceTimer?
    private var configuration: PipelineConfiguration?
    private var caller: AudioEndpoint?
    private var agent: AudioEndpoint?
    private var agentInput: AudioEndpoint?
    private var reply: AudioEndpoint?
    private var monitor: AudioEndpoint?
    private var tap: AppAudioTap?
    private var callerCaptureError: AppFailure?
    private var agentCaptureError: AppFailure?
    private var callerOutputError: AppFailure?
    private var agentOutputError: AppFailure?
    private var callerTimeline = StereoTimeline()
    private var agentTimeline = StereoTimeline()
    private var callerWaveform = LiveWaveformHistory()
    private var agentWaveform = LiveWaveformHistory()
    private let origin = sb_host_seconds(sb_host_time())
    private var lastMonitorFrame: Int64?
    private var state = PipelineSnapshot()
    private var recorder: ConversationRecorder?
    private var sessionID: UUID?
    private var sessionClock: SessionAudioClock?
    private var acceptingAfter: Double = .infinity
    private var relaying = false
    private var recording = false
    private var transcriptFeeds: TranscriptFeeds?
    private var transcriptHistory: AudioHistory?
    private var transcriptOwner: UUID?
    private var transcriptAfterFrame: [AudioSide: Int64] = [:]

    init() {
        let timer = DispatchSource.makeTimerSource(queue: work.dispatchQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.tick() }
        self.timer = timer
        timer.resume()
    }

    func configure(
        callerID: UInt32?, agentInputID: UInt32?, replyID: UInt32?, monitorID: UInt32?,
        agentTarget: AppAudioTarget?, callerVolume: Float = 1, agentVolume: Float = 1
    ) {
        let next = PipelineConfiguration(
            callerID: callerID, agentInputID: agentInputID, replyID: replyID, monitorID: monitorID,
            agentTarget: agentTarget, callerVolume: callerVolume, agentVolume: agentVolume)
        let schedule = pendingConfiguration.withLock { pending in
            let schedule = pending == nil
            pending = next
            return schedule
        }
        guard schedule else { return }
        work.submit { [self] in
            guard
                let next = pendingConfiguration.withLock({ pending in
                    defer { pending = nil }
                    return pending
                })
            else { return }
            configuration = next
            applyConfiguration()
        }
    }

    func configureMonitoring(monitorID: UInt32?, callerVolume: Float, agentVolume: Float) {
        let next = MonitoringConfiguration(
            monitorID: monitorID, callerVolume: callerVolume, agentVolume: agentVolume)
        let schedule = pendingMonitoring.withLock { pending in
            let schedule = pending == nil
            pending = next
            return schedule
        }
        guard schedule else { return }
        work.submit { [self] in
            guard
                let next = pendingMonitoring.withLock({ pending in
                    defer { pending = nil }
                    return pending
                }), var current = configuration
            else { return }
            current.monitorID = next.monitorID
            current.callerVolume = next.callerVolume
            current.agentVolume = next.agentVolume
            configuration = current
            applyConfiguration()
        }
    }

    private func applyConfiguration() {
        guard sessionID != nil, let next = configuration else { return }
        guard relaying else {
            releaseEndpoints()
            state.callerReady = false
            state.agentReady = false
            state.monitorReady = false
            state.callerLevel = 0
            state.agentLevel = 0
            publish()
            return
        }
        if caller?.deviceID != next.callerID || caller?.needsRestart == true {
            caller = nil
            callerCaptureError = nil
            if let id = next.callerID {
                do {
                    caller = try AudioEndpoint(deviceID: id, capture: true)
                } catch { callerCaptureError = AppFailure(error) }
            }
        }
        if tap?.target != next.agentTarget || agent?.needsRestart == true {
            agent = nil
            tap = nil
            agentCaptureError = nil
        }
        if let target = next.agentTarget, tap == nil {
            do {
                let newTap = AppAudioTap(target: target)
                try newTap.start()
                agent = try AudioEndpoint(deviceID: newTap.deviceID, capture: true)
                tap = newTap
                agentCaptureError = nil
            } catch { agentCaptureError = AppFailure(error) }
        }
        configureOutput(&agentInput, id: next.agentInputID, failure: &callerOutputError)
        configureOutput(&reply, id: next.replyID, failure: &agentOutputError)
        if monitor?.deviceID != next.monitorID || monitor?.needsRestart == true {
            lastMonitorFrame = nil
        }
        configureOutput(&monitor, id: next.monitorID, failure: &state.monitorError)
        state.callerError = callerCaptureError ?? callerOutputError
        state.agentError = agentCaptureError ?? agentOutputError
        state.callerReady = caller != nil && agentInput != nil
        state.agentReady = agent != nil && reply != nil
        state.monitorReady = monitor != nil
        publish()
    }

    private func configureOutput(_ endpoint: inout AudioEndpoint?, id: UInt32?, failure: inout AppFailure?) {
        guard endpoint?.deviceID != id || endpoint?.needsRestart == true else { return }
        endpoint = nil
        failure = nil
        if let id {
            do {
                endpoint = try AudioEndpoint(deviceID: id, capture: false)
                failure = nil
            } catch { failure = AppFailure(error) }
        }
    }

    func requestCapturePermission(target: AppAudioTarget) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            permissionWork.async { [self] in
                do {
                    permissionGeneration &+= 1
                    let generation = permissionGeneration
                    permissionRequest = nil
                    permissionRequest = try CapturePermissionRequest(target: target)
                    permissionWork.asyncAfter(deadline: .now() + 30) { [weak self] in
                        guard let self, permissionGeneration == generation else { return }
                        permissionRequest = nil
                    }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func startSession(directory: URL, manifest: RecordingManifest) async throws {
        var timebase = mach_timebase_info_data_t()
        guard mach_timebase_info(&timebase) == KERN_SUCCESS else { throw MediaFailure.invalidBuffer }
        let hostBefore = sb_host_time()
        let continuous = mach_continuous_time()
        let hostAfter = sb_host_time()
        guard
            let clock = SessionAudioClock(
                hostBefore: hostBefore, continuous: continuous, hostAfter: hostAfter,
                timebaseNumerator: timebase.numer, timebaseDenominator: timebase.denom)
        else { throw MediaFailure.invalidBuffer }
        let id = manifest.id
        let recorder = ConversationRecorder { [weak self] failure in
            self?.work.submit { [weak self] in
                guard let self, sessionID == id else { return }
                recording = false
                state.recordingError = AppFailure(failure)
            }
        }
        _ = try await files.run { try recorder.start(directory: directory, manifest: manifest) }
        await work.complete { [self] in
            self.recorder = recorder
            sessionID = id
            sessionClock = clock
            acceptingAfter = sb_host_seconds(sb_host_time())
            relaying = true
            recording = true
            state.recordingError = nil
            applyConfiguration()
        }
    }

    /// Returns the exact session frame at which the new controls take effect.
    func setControls(relaying: Bool, recording: Bool) async -> Int64 {
        await work.complete { [self] in
            let frame = elapsedFrame()
            if self.relaying != relaying {
                acceptingAfter = sb_host_seconds(sb_host_time())
                callerTimeline = StereoTimeline()
                agentTimeline = StereoTimeline()
                callerWaveform = LiveWaveformHistory()
                agentWaveform = LiveWaveformHistory()
                lastMonitorFrame = nil
            }
            self.relaying = relaying
            self.recording = relaying && recording
            applyConfiguration()
            return frame
        }
    }

    func currentSessionFrame() async -> Int64 { await work.complete { [self] in elapsedFrame() } }

    func beginTranscriptBuffering() async -> AudioHistorySnapshot {
        await work.complete { [self] in
            transcriptFeeds = nil
            var history = AudioHistory(beginFrame: elapsedFrame())
            let snapshot = history.snapshot()
            transcriptOwner = history.id
            transcriptHistory = history
            return snapshot
        }
    }

    func transcriptHistorySnapshot(
        for id: UUID, acknowledging frames: [AudioSide: Int64]
    ) async -> AudioHistorySnapshot? {
        await work.complete { [self] in
            guard transcriptOwner == id, transcriptHistory?.id == id else { return nil }
            return transcriptHistory?.snapshot(acknowledging: frames)
        }
    }

    /// The receipt is captured after the history snapshot, before sealing all recorder work already admitted.
    func checkpointTranscript(for historyID: UUID) async throws -> TranscriptReplayCheckpoint? {
        let captured: (ConversationRecorder?, UInt64, Int64)? = await work.complete { [self] in
            guard transcriptOwner == historyID, let history = transcriptHistory, history.id == historyID
            else { return nil }
            return (recorder, history.sequence, elapsedFrame())
        }
        guard let captured else { return nil }
        let snapshot = try await files.run { try captured.0?.checkpoint(durationFrames: captured.2) }
        return try TranscriptReplayCheckpoint(
            historyID: historyID, sequence: captured.1,
            manifest: snapshot?.manifest, directory: snapshot?.directory)
    }

    func attachTranscript(
        _ feeds: TranscriptFeeds, historyID: UUID, after frames: [AudioSide: Int64],
        supportedSides: Set<AudioSide>
    ) async -> AudioHistoryAttachment {
        await work.complete { [self] in
            guard transcriptOwner == historyID,
                let result = transcriptHistory?.prepareAttachment(
                    expectedID: historyID, acknowledging: frames, supportedSides: supportedSides)
            else { return .obsolete }
            if case .attached = result {
                // Empty-tail attachment is atomic. Replay never falls through the lossy live admission path.
                transcriptHistory = nil
                transcriptAfterFrame = Dictionary(
                    uniqueKeysWithValues: AudioSide.allCases.map {
                        ($0, supportedSides.contains($0) ? frames[$0, default: 0] : Int64.max)
                    })
                transcriptFeeds = feeds
            }
            return result
        }
    }

    func detachTranscript(historyID: UUID? = nil) async {
        await work.complete { [self] in
            guard historyID == nil || transcriptOwner == historyID else { return }
            transcriptFeeds = nil
            transcriptHistory = nil
            transcriptOwner = nil
        }
    }

    func checkpoint(durationFrames: Int64? = nil) async throws -> RecorderSnapshot? {
        let captured = await work.complete { [self] in (recorder, durationFrames ?? elapsedFrame()) }
        guard let recorder = captured.0 else { return nil }
        return try await files.run { try recorder.checkpoint(durationFrames: captured.1) }
    }

    func finishSession(durationFrames: Int64? = nil) async throws -> URL? {
        pendingConfiguration.withLock { $0 = nil }
        pendingMonitoring.withLock { $0 = nil }
        let captured = await work.complete { [self] in
            let result = (recorder, durationFrames ?? elapsedFrame())
            recorder = nil
            sessionID = nil
            sessionClock = nil
            relaying = false
            recording = false
            transcriptFeeds = nil
            transcriptHistory = nil
            releaseRoutes()
            return result
        }
        guard let recorder = captured.0 else { return nil }
        let result = await files.complete { Result { try recorder.finish(durationFrames: captured.1) } }
        return try result.get()
    }

    func shutdownRoutes() async {
        pendingConfiguration.withLock { $0 = nil }
        pendingMonitoring.withLock { $0 = nil }
        await work.complete { [self] in releaseRoutes() }
    }

    private func releaseEndpoints() {
        agent = nil
        tap = nil
        caller = nil
        agentInput = nil
        reply = nil
        monitor = nil
        callerTimeline = StereoTimeline()
        agentTimeline = StereoTimeline()
        callerWaveform = LiveWaveformHistory()
        agentWaveform = LiveWaveformHistory()
        lastMonitorFrame = nil
        callerCaptureError = nil
        agentCaptureError = nil
        callerOutputError = nil
        agentOutputError = nil
        permissionWork.async { [self] in
            permissionGeneration &+= 1
            permissionRequest = nil
        }
    }

    private func releaseRoutes() {
        releaseEndpoints()
        state = PipelineSnapshot()
        publish()
    }

    func snapshot() -> PipelineSnapshot {
        var result = publication.withLock { $0 }
        if sb_host_seconds(sb_host_time()) - result.updatedAt > 1 {
            result.callerLevel = 0
            result.agentLevel = 0
            result.callerWaveform = [Float](repeating: 0, count: LiveWaveformHistory.count)
            result.agentWaveform = result.callerWaveform
        }
        return result
    }

    private func publish() {
        state.updatedAt = sb_host_seconds(sb_host_time())
        publication.withLock { $0 = state }
    }

    private func elapsedFrame() -> Int64 {
        guard sessionID != nil else { return 0 }
        return sessionClock?.elapsedFrame(atContinuousTime: mach_continuous_time()) ?? 0
    }

    private func tick() {
        guard sessionID != nil else { return }
        let hostBefore = sb_host_time()
        let continuous = mach_continuous_time()
        let hostAfter = sb_host_time()
        if sessionClock?.observe(hostBefore: hostBefore, continuous: continuous, hostAfter: hostAfter)
            == .sleep
        {
            acceptingAfter = sb_host_seconds(hostAfter)
            releaseEndpoints()
            applyConfiguration()
        }
        let now = sb_host_seconds(hostAfter)
        let frame = elapsedFrame()
        state.callerLevel *= 0.85
        state.agentLevel *= 0.85
        consume(caller, side: .caller)
        consume(agent, side: .agent)
        state.callerWaveform = callerWaveform.samples(endingAt: now)
        state.agentWaveform = agentWaveform.samples(endingAt: now)
        if let monitor, let configuration {
            let end = Int64((now - origin - 0.06) * PCM.rate)
            let start = max(lastMonitorFrame ?? (end - 480), end - 2400)
            if end > start, start >= 0 {
                let a = callerTimeline.read(at: start, frames: Int(end - start))
                let b = agentTimeline.read(at: start, frames: Int(end - start))
                let mixed = zip(a, b).map {
                    min(1, max(-1, ($0 * configuration.callerVolume + $1 * configuration.agentVolume) * 0.5))
                }
                do { try monitor.push(mixed) } catch { state.monitorError = AppFailure(error) }
            }
            lastMonitorFrame = end
        }
        state.recordedSeconds = Double(frame) / PCM.rate
        state.droppedFrames =
            (caller.map { sb_queue_dropped($0.queue) } ?? 0)
            + (agent.map { sb_queue_dropped($0.queue) } ?? 0)
        state.agentInputUnderruns = agentInput.map { sb_endpoint_underruns($0.handle) } ?? 0
        state.replyUnderruns = reply.map { sb_endpoint_underruns($0.handle) } ?? 0
        state.monitorUnderruns = monitor.map { sb_endpoint_underruns($0.handle) } ?? 0
        publish()
    }

    private func consume(_ endpoint: AudioEndpoint?, side: AudioSide) {
        guard let endpoint else { return }
        do {
            for packet in try endpoint.packets() {
                let seconds = sb_host_seconds(packet.hostTime)
                guard relaying, seconds >= acceptingAfter,
                    let frame = sessionClock?.frame(forHostTime: packet.hostTime),
                    frame > -Int64(packet.samples.count / 2)
                else { continue }
                let start = Int64(((seconds - origin) * PCM.rate).rounded())
                let level = packet.samples.reduce(Float(0)) { max($0, abs($1)) }
                if side == .caller {
                    callerWaveform.insert(peak: level, seconds: seconds)
                    callerTimeline.insert(packet.samples, at: start)
                    state.callerLevel = max(state.callerLevel, level)
                    try agentInput?.push(packet.samples)
                } else {
                    agentWaveform.insert(peak: level, seconds: seconds)
                    agentTimeline.insert(packet.samples, at: start)
                    state.agentLevel = max(state.agentLevel, level)
                    try reply?.push(packet.samples)
                }
                let skip = min(packet.samples.count / 2, Int(max(0, -frame)))
                let samples = Array(packet.samples.dropFirst(skip * 2))
                guard !samples.isEmpty else { continue }
                let position = max(0, frame)
                if recording, let recorder,
                    !recorder.append(side: side, samples: samples, frame: position)
                {
                    recording = false
                    state.recordingError = .media(.overrun)
                }
                if transcriptFeeds != nil || transcriptHistory != nil {
                    for offset in stride(from: 0, to: samples.count, by: 9600) {
                        let chunk = Array(samples[offset..<min(offset + 9600, samples.count)])
                        let packet = try TimedAudio(
                            side: side, samples: chunk, startFrame: position + Int64(offset / 2))
                        if let transcriptFeeds, let trimmed = packet.after(transcriptAfterFrame[side] ?? 0) {
                            _ = transcriptFeeds.append(
                                side: side, samples: trimmed.samples, startFrame: trimmed.startFrame)
                        } else {
                            transcriptHistory?.append(packet)
                        }
                    }
                }
            }
            let status = sb_endpoint_error(endpoint.handle)
            if status != 0 { throw AudioFailure(operation: .errorInputInterrupted, code: status) }
        } catch {
            if side == .caller {
                state.callerError = AppFailure(error)
            } else {
                state.agentError = AppFailure(error)
            }
        }
    }

    deinit { timer?.cancel() }
}

private struct PipelineConfiguration: Sendable {
    let callerID: UInt32?
    let agentInputID: UInt32?
    let replyID: UInt32?
    var monitorID: UInt32?
    let agentTarget: AppAudioTarget?
    var callerVolume: Float
    var agentVolume: Float
}

private struct MonitoringConfiguration: Sendable {
    let monitorID: UInt32?
    let callerVolume: Float
    let agentVolume: Float
}
