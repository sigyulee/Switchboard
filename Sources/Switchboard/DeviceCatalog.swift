import CoreAudio
import Foundation

struct AudioDevice: Identifiable, Equatable, Sendable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let input: Bool
    let output: Bool
    let transport: UInt32
    let alive: Bool
    var physical: Bool {
        transport != kAudioDeviceTransportTypeVirtual && transport != kAudioDeviceTransportTypeAggregate
    }
    var builtIn: Bool { transport == kAudioDeviceTransportTypeBuiltIn }
    var airPods: Bool { name.localizedCaseInsensitiveContains("airpod") }
}

struct AudioFailure: Error, LocalizedError, Sendable {
    let operation: TextKey
    let code: Int32
    var detail: String? = nil
    var errorDescription: String? { AppStrings(language: .english).error(self) }
}

enum AudioDevices {
    static let callerUID = "MIHCaller_UID"
    static let replyUID = "MIHReply_UID"
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
    static func scalar<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, initial: T) -> T {
        var value = initial
        var addr = address(selector)
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0)
        }
        return status == noErr ? value : initial
    }
    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String {
        var value: Unmanaged<CFString>?
        var addr = address(selector)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return "" }
        return value.takeRetainedValue() as String
    }
    static func objects(
        _ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> [AudioObjectID] {
        var addr = address(selector, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else {
            return []
        }
        var values = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        let status = values.withUnsafeMutableBytes { buffer -> OSStatus in
            guard let base = buffer.baseAddress else { return kAudioHardwareBadPropertySizeError }
            return AudioObjectGetPropertyData(object, &addr, 0, nil, &size, base)
        }
        return status == noErr ? values : []
    }
    static func all() -> [AudioDevice] {
        objects(system, kAudioHardwarePropertyDevices).map { id in
            AudioDevice(
                id: id, uid: string(id, kAudioDevicePropertyDeviceUID),
                name: string(id, kAudioObjectPropertyName),
                input: !objects(id, kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeInput)
                    .isEmpty,
                output: !objects(id, kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeOutput)
                    .isEmpty,
                transport: scalar(id, kAudioDevicePropertyTransportType, initial: UInt32(0)),
                alive: scalar(id, kAudioDevicePropertyDeviceIsAlive, initial: UInt32(0)) != 0)
        }.filter { !$0.uid.isEmpty }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    static func defaultInput() -> AudioObjectID {
        scalar(system, kAudioHardwarePropertyDefaultInputDevice, initial: UInt32(0))
    }
    static func setDefaultInput(_ id: AudioDeviceID) throws {
        var id = id
        var addr = address(kAudioHardwarePropertyDefaultInputDevice)
        let status = AudioObjectSetPropertyData(
            system, &addr, 0, nil, UInt32(MemoryLayout.size(ofValue: id)), &id)
        guard status == noErr else { throw AudioFailure(operation: .errorDefaultInput, code: status) }
    }
}
