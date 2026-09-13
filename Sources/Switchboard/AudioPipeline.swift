import AudioRealtime
import BridgeCore
import Foundation
import RecorderKit
import Synchronization

struct PipelineSnapshot: Sendable, Equatable {
    var updatedAt: Double = 0
    var callerReady = false
    var chromeReady = false
    var monitorReady = false
    var callerLevel: Float = 0
    var chromeLevel: Float = 0
    var callerWaveform = [Float](repeating: 0, count: LiveWaveformHistory.count)
    var chromeWaveform = [Float](repeating: 0, count: LiveWaveformHistory.count)
    var callerError: AppFailure?
    var chromeError: AppFailure?
    var monitorError: AppFailure?
    var recordingError: AppFailure?
    var recordedSeconds: Double = 0
    var droppedFrames: UInt64 = 0
}

// Device lifetimes and state are confined to work. C callbacks only access their SPSC queue.
final class AudioPipeline: @unchecked Sendable {
    private let work = AsyncSerialQueue(label: "com.switchboard.main.audio", qos: .userInteractive)
    private let files = AsyncSerialQueue(label: "com.switchboard.main.audio-files", qos: .utility)
    private let pendingConfiguration = Mutex<PipelineConfiguration?>(nil)
    private let permissionWork = DispatchQueue(
        label: "com.switchboard.main.audio-permission", qos: .userInitiated)
    private let publication = NSLock()
    private var published = PipelineSnapshot()
    private var timer: DispatchSourceTimer?
    private var caller: AudioEndpoint?
    private var chrome: AudioEndpoint?
    private var reply: AudioEndpoint?
    private var monitor: AudioEndpoint?
    private var tap: ChromeTap?
    private var permissionRequest: CapturePermissionRequest?
    private var permissionGeneration: UInt64 = 0
    private var callerTimeline = StereoTimeline()
    private var chromeTimeline = StereoTimeline()
    private var callerWaveform = LiveWaveformHistory()
    private var chromeWaveform = LiveWaveformHistory()
    private let origin = sb_host_seconds(sb_host_time())
    private var lastMonitorFrame: Int64?
    private var callerVolume: Float = 1
    private var chromeVolume: Float = 1
    private var state = PipelineSnapshot()
    private var recorder: ConversationRecorder?
    private var recordingID: UUID?
    private var recordOrigin: Double = 0

    init() {
        let timer = DispatchSource.makeTimerSource(queue: work.dispatchQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.tick() }
        self.timer = timer
        timer.resume()
    }

    func configure(
        callerID: UInt32?, replyID: UInt32?, monitorID: UInt32?, chromeRunning: Bool,
        callerVolume: Float = 1, chromeVolume: Float = 1
    ) {
        let next = PipelineConfiguration(
            callerID: callerID, replyID: replyID, monitorID: monitorID,
            chromeRunning: chromeRunning, callerVolume: callerVolume, chromeVolume: chromeVolume)
        let schedule = pendingConfiguration.withLock { pending in
            let schedule = pending == nil
            pending = next
            return schedule
        }
        guard schedule else { return }
        work.submit { [self] in
            let next = pendingConfiguration.withLock { pending in
                defer { pending = nil }
                return pending
            }
            guard let next else { return }
            let (callerID, replyID, monitorID, chromeRunning) =
                (next.callerID, next.replyID, next.monitorID, next.chromeRunning)
            self.callerVolume = next.callerVolume
            self.chromeVolume = next.chromeVolume
            if caller?.deviceID != callerID || caller?.needsRestart == true {
                caller = nil
                if let id = callerID {
                    do {
                        caller = try AudioEndpoint(deviceID: id, capture: true)
                        state.callerError = nil
                    } catch { state.callerError = AppFailure(error) }
                }
            }
            if reply?.deviceID != replyID || reply?.needsRestart == true {
                reply = nil
                if let id = replyID {
                    do { reply = try AudioEndpoint(deviceID: id, capture: false) } catch {
                        state.chromeError = AppFailure(error)
                    }
                }
            }
            if !chromeRunning || tap?.membershipChanged() == true || chrome?.needsRestart == true {
                chrome = nil
                tap = nil
            }
            if chromeRunning, tap == nil, reply != nil {
                do {
                    let newTap = ChromeTap()
                    try newTap.start()
                    chrome = try AudioEndpoint(deviceID: newTap.deviceID, capture: true)
                    tap = newTap
                    state.chromeError = nil
                } catch { state.chromeError = AppFailure(error) }
            }
            if monitor?.deviceID != monitorID || monitor?.needsRestart == true {
                monitor = nil
                lastMonitorFrame = nil
                if let id = monitorID {
                    do {
                        monitor = try AudioEndpoint(deviceID: id, capture: false)
                        state.monitorError = nil
                    } catch { state.monitorError = AppFailure(error) }
                }
            }
            state.callerReady = caller != nil
            state.chromeReady = chrome != nil && reply != nil
            state.monitorReady = monitor != nil
            publish()
        }
    }
    func requestCapturePermission() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            permissionWork.async { [self] in
                do {
                    permissionGeneration &+= 1
                    let generation = permissionGeneration
                    permissionRequest = nil
                    permissionRequest = try CapturePermissionRequest()
                    permissionWork.asyncAfter(deadline: .now() + 30) { [weak self] in
                        guard let self, permissionGeneration == generation else { return }
                        permissionRequest = nil
                    }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    func snapshot() -> PipelineSnapshot {
        var result = publication.withLock { published }
        if sb_host_seconds(sb_host_time()) - result.updatedAt > 1 {
            result.callerLevel = 0
            result.chromeLevel = 0
            result.callerWaveform = [Float](repeating: 0, count: LiveWaveformHistory.count)
            result.chromeWaveform = result.callerWaveform
        }
        return result
    }
    private func publish() {
        state.updatedAt = sb_host_seconds(sb_host_time())
        publication.withLock { published = state }
    }
    func shutdownRoutes() async {
        pendingConfiguration.withLock { $0 = nil }
        await work.complete { [self] in
            chrome = nil
            tap = nil
            caller = nil
            reply = nil
            monitor = nil
            callerWaveform = LiveWaveformHistory()
            chromeWaveform = LiveWaveformHistory()
            lastMonitorFrame = nil
            state = PipelineSnapshot()
            publish()
            permissionWork.async { [self] in
                permissionGeneration &+= 1
                permissionRequest = nil
            }
        }
    }
    func startRecording(root: URL, owner: RecordingOwner) async throws -> URL {
        let id = UUID()
        let recorder = ConversationRecorder { [weak self] message in
            self?.work.submit { [weak self] in
                guard let self, recordingID == id else { return }
                state.recordingError = AppFailure(message)
            }
        }
        let url = try await files.run { try recorder.start(root: root, owner: owner) }
        await work.complete { [self] in
            self.recorder = recorder
            recordingID = id
            recordOrigin = sb_host_seconds(sb_host_time())
            state.recordingError = nil
        }
        return url
    }
    func stopRecording() async throws -> URL? {
        let stopped: (ConversationRecorder?, Int64) = await work.complete { [self] in
            let value = recorder
            recorder = nil
            recordingID = nil
            return (value, Int64(max(0, sb_host_seconds(sb_host_time()) - recordOrigin) * PCM.rate))
        }
        guard let recorder = stopped.0 else { return nil }
        let result = await files.complete { Result { try recorder.finish(durationFrames: stopped.1) } }
        return try result.get()
    }

    private func tick() {
        let now = sb_host_seconds(sb_host_time())
        state.callerLevel *= 0.85
        state.chromeLevel *= 0.85
        consume(caller, side: .caller)
        consume(chrome, side: .chrome)
        state.callerWaveform = callerWaveform.samples(endingAt: now)
        state.chromeWaveform = chromeWaveform.samples(endingAt: now)
        if let monitor {
            let end = Int64((now - origin - 0.06) * PCM.rate)
            let start = max(lastMonitorFrame ?? (end - 480), end - 2400)
            if end > start, start >= 0 {
                let a = callerTimeline.read(at: start, frames: Int(end - start))
                let b = chromeTimeline.read(at: start, frames: Int(end - start))
                let mixed = zip(a, b).map { min(1, max(-1, ($0 * callerVolume + $1 * chromeVolume) * 0.5)) }
                do { try monitor.push(mixed) } catch { state.monitorError = AppFailure(error) }
            }
            lastMonitorFrame = end
        }
        if recorder != nil { state.recordedSeconds = max(0, now - recordOrigin) }
        state.droppedFrames =
            (caller.map { sb_queue_dropped($0.queue) } ?? 0)
            + (chrome.map { sb_queue_dropped($0.queue) } ?? 0)
        publish()
    }
    private func consume(_ endpoint: AudioEndpoint?, side: AudioSide) {
        guard let endpoint else { return }
        do {
            for packet in try endpoint.packets() {
                let start = Int64(((packet.seconds - origin) * PCM.rate).rounded())
                let level = packet.samples.reduce(Float(0)) { max($0, abs($1)) }
                if side == .caller {
                    callerWaveform.insert(peak: level, seconds: packet.seconds)
                } else {
                    chromeWaveform.insert(peak: level, seconds: packet.seconds)
                }
                if side == .caller {
                    callerTimeline.insert(packet.samples, at: start)
                    state.callerLevel = max(state.callerLevel, level)
                } else {
                    chromeTimeline.insert(packet.samples, at: start)
                    state.chromeLevel = max(state.chromeLevel, level)
                    try reply?.push(packet.samples)
                }
                if let recorder {
                    let frame = Int64(((packet.seconds - recordOrigin) * PCM.rate).rounded())
                    let skip = min(packet.samples.count / 2, Int(max(0, -frame)))
                    let samples = Array(packet.samples.dropFirst(skip * 2))
                    if !samples.isEmpty, !recorder.append(side: side, samples: samples, frame: max(0, frame))
                    {
                        state.recordingError = .media(.overrun)
                    }
                }
            }
            let status = sb_endpoint_error(endpoint.handle)
            if status != 0 { throw AudioFailure(operation: .errorInputInterrupted, code: status) }
        } catch {
            if side == .caller {
                state.callerError = AppFailure(error)
            } else {
                state.chromeError = AppFailure(error)
            }
        }
    }
    deinit { timer?.cancel() }
}

private struct PipelineConfiguration: Sendable {
    let callerID: UInt32?
    let replyID: UInt32?
    let monitorID: UInt32?
    let chromeRunning: Bool
    let callerVolume: Float
    let chromeVolume: Float
}
