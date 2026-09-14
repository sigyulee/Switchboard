import BridgeCore
import CoreAudio
import Foundation

/// Polls only public HAL metadata. This does not capture audio, watch amplitude,
/// change routes, or identify a Phone call/handoff. The parent owns polling.
@MainActor final class CallerRouteObserver {
    private struct Selection: Equatable {
        let sessionID: UUID
        let application: ApplicationIdentity
    }

    private var selection: Selection?
    private var reducer = CallerRouteState()
    private var previouslyVerified: Set<AudioObjectID> = []

    var status: CallerRouteStatus { reducer.status }
    var evidence: CallerRouteEvidence { reducer.evidence }
    var isArmed: Bool { reducer.isArmed }

    /// Explicit Resume must reset before polling; returning routes cannot resume
    /// a session automatically or reuse observations from its previous epoch.
    func reset() {
        selection = nil
        reducer = CallerRouteState()
        previouslyVerified = []
    }

    @discardableResult
    func poll(
        sessionID: UUID, application: ApplicationIdentity,
        speakerDeviceID: AudioDeviceID?, microphoneDeviceID: AudioDeviceID?,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> CallerRouteStatus {
        let next = Selection(sessionID: sessionID, application: application)
        if selection != next {
            reset()
            selection = next
            reducer.reset(sessionID: sessionID, callerID: application.bundleIdentifier)
        }
        guard let epoch = reducer.epoch else { return .unknown }
        let sample: CallerRouteEvidence
        do {
            try application.validate()
            guard let speakerDeviceID, let microphoneDeviceID, speakerDeviceID != 0,
                microphoneDeviceID != 0, speakerDeviceID != microphoneDeviceID,
                try Self.string(speakerDeviceID, kAudioDevicePropertyDeviceUID) == AudioDevices.callerUID,
                try Self.string(microphoneDeviceID, kAudioDevicePropertyDeviceUID) == AudioDevices.replyUID
            else { throw CallerRouteIssue.unavailableDevices }
            sample = try collect(
                application: application, speaker: speakerDeviceID, microphone: microphoneDeviceID)
        } catch let issue as CallerRouteIssue {
            sample = .unknown(issue)
        } catch {
            sample = .unknown(.unverifiedProcesses)
        }
        return reducer.observe(sample, at: now, epoch: epoch)
    }

    private func collect(
        application: ApplicationIdentity, speaker: AudioDeviceID, microphone: AudioDeviceID
    ) throws -> CallerRouteEvidence {
        let before = Set(try Self.processObjects())
        // This catalog checks executable-path ownership, including nested helpers.
        // Never broaden its result to shared WebKit or telephony services.
        let target = ApplicationCatalog.audioTarget(for: application)
        let processes = Set(target.processes)
        let after = Set(try Self.processObjects())
        guard before == after, processes.isSubset(of: after) else {
            throw CallerRouteIssue.unstableProcessList
        }
        // An object still listed by HAL but no longer verifiable by the catalog
        // may reflect a failed PID/path query or reuse. That is not disappearance.
        guard previouslyVerified.intersection(after).subtracting(processes).isEmpty else {
            throw CallerRouteIssue.unverifiedProcesses
        }
        if processes.isEmpty {
            guard !previouslyVerified.isEmpty, previouslyVerified.isDisjoint(with: after) else {
                throw CallerRouteIssue.unverifiedProcesses
            }
            // Retain the last verified IDs so successive successful empty samples
            // can complete the debounce instead of forgetting the known family.
            return CallerRouteEvidence(
                verifiedProcessCount: 0, speakerAssociated: false, microphoneAssociated: false,
                isRunningOutput: false, isRunningInput: false)
        }
        guard processes.count <= 256 else { throw CallerRouteIssue.invalidPropertySize }
        var speakerAssociated = false
        var microphoneAssociated = false
        var runningOutput = false
        var runningInput = false
        var classes: [AudioObjectID: AudioClassID] = [:]
        for process in processes.sorted() {
            let outputs = try Self.objects(
                process, kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeOutput)
            let inputs = try Self.objects(
                process, kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeInput)
            let outputMember = outputs.contains(speaker)
            let inputMember = inputs.contains(microphone)
            // Aggregate membership alone does not reveal foreign-client channel
            // routing. Leave that profile unknown instead of declaring route loss.
            if !outputMember { try Self.requireDirectDevices(outputs, classes: &classes) }
            if !inputMember { try Self.requireDirectDevices(inputs, classes: &classes) }
            let outputActive = try Self.running(process, kAudioProcessPropertyIsRunningOutput)
            let inputActive = try Self.running(process, kAudioProcessPropertyIsRunningInput)
            speakerAssociated = speakerAssociated || outputMember
            microphoneAssociated = microphoneAssociated || inputMember
            runningOutput = runningOutput || (outputMember && outputActive)
            runningInput = runningInput || (inputMember && inputActive)
        }
        guard Set(try Self.processObjects()) == after else { throw CallerRouteIssue.unstableProcessList }
        previouslyVerified = processes
        return CallerRouteEvidence(
            verifiedProcessCount: processes.count, speakerAssociated: speakerAssociated,
            microphoneAssociated: microphoneAssociated, isRunningOutput: runningOutput,
            isRunningInput: runningInput)
    }

    private static func processObjects() throws -> [AudioObjectID] {
        try objects(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList)
    }

    private static func requireDirectDevices(
        _ devices: [AudioObjectID], classes: inout [AudioObjectID: AudioClassID]
    ) throws {
        for device in devices {
            let kind: AudioClassID
            if let known = classes[device] {
                kind = known
            } else {
                kind = try scalar(device, kAudioObjectPropertyClass)
                classes[device] = kind
            }
            if kind == kAudioAggregateDeviceClassID { throw CallerRouteIssue.indirectDevice }
        }
    }

    private static func propertySize(
        _ object: AudioObjectID, address: inout AudioObjectPropertyAddress
    ) throws -> UInt32 {
        guard AudioObjectHasProperty(object, &address) else { throw CallerRouteIssue.unsupportedProperty }
        var size: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size)
        guard status == noErr else { throw CallerRouteIssue.queryFailed(status) }
        return size
    }

    private static func objects(
        _ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) throws -> [AudioObjectID] {
        var address = AudioDevices.address(selector, scope: scope)
        let stride = UInt32(MemoryLayout<AudioObjectID>.stride)
        for attempt in 0..<2 {
            var size = try propertySize(object, address: &address)
            guard size % stride == 0, size / stride <= 4_096 else {
                throw CallerRouteIssue.invalidPropertySize
            }
            if size == 0 { return [] }
            let capacity = size
            var values = [AudioObjectID](repeating: 0, count: Int(size / stride))
            let status = values.withUnsafeMutableBytes { bytes in
                guard let base = bytes.baseAddress else { return kAudioHardwareBadPropertySizeError }
                return AudioObjectGetPropertyData(object, &address, 0, nil, &size, base)
            }
            if status == kAudioHardwareBadPropertySizeError, attempt == 0 { continue }
            guard status == noErr else { throw CallerRouteIssue.queryFailed(status) }
            guard size <= capacity, size % stride == 0 else { throw CallerRouteIssue.invalidPropertySize }
            values.removeLast(values.count - Int(size / stride))
            guard !values.contains(kAudioObjectUnknown), Set(values).count == values.count else {
                throw CallerRouteIssue.invalidEvidence
            }
            return values
        }
        throw CallerRouteIssue.unstableProcessList
    }

    private static func scalar(
        _ object: AudioObjectID, _ selector: AudioObjectPropertySelector
    ) throws -> UInt32 {
        var address = AudioDevices.address(selector)
        var size = try propertySize(object, address: &address)
        guard size == UInt32(MemoryLayout<UInt32>.size) else { throw CallerRouteIssue.invalidPropertySize }
        var value: UInt32 = 0
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
        guard status == noErr else { throw CallerRouteIssue.queryFailed(status) }
        guard size == UInt32(MemoryLayout<UInt32>.size) else { throw CallerRouteIssue.invalidPropertySize }
        return value
    }

    private static func running(
        _ object: AudioObjectID, _ selector: AudioObjectPropertySelector
    ) throws -> Bool {
        let value = try scalar(object, selector)
        guard value <= 1 else { throw CallerRouteIssue.invalidEvidence }
        return value == 1
    }

    private static func string(
        _ object: AudioObjectID, _ selector: AudioObjectPropertySelector
    ) throws -> String {
        var address = AudioDevices.address(selector)
        var size = try propertySize(object, address: &address)
        guard size == UInt32(MemoryLayout<Unmanaged<CFString>?>.size) else {
            throw CallerRouteIssue.invalidPropertySize
        }
        var value: Unmanaged<CFString>?
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
        guard status == noErr else { throw CallerRouteIssue.queryFailed(status) }
        guard let value else { throw CallerRouteIssue.invalidEvidence }
        let string = value.takeRetainedValue()
        guard size == UInt32(MemoryLayout<Unmanaged<CFString>?>.size),
            CFGetTypeID(string) == CFStringGetTypeID()
        else { throw CallerRouteIssue.invalidPropertySize }
        return string as String
    }
}
