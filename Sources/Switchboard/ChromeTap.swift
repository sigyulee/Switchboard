import CoreAudio
import Foundation

final class ChromeTap {
    private(set) var tapID: AudioObjectID = 0
    private(set) var deviceID: AudioDeviceID = 0
    private var members: Set<AudioObjectID> = []

    static func processes() -> [AudioObjectID] {
        AudioDevices.objects(AudioDevices.system, kAudioHardwarePropertyProcessObjectList).filter {
            let bundle = AudioDevices.string($0, kAudioProcessPropertyBundleID)
            return bundle == "com.google.Chrome" || bundle.hasPrefix("com.google.Chrome.helper")
        }
    }
    func start(requireRunningProcess: Bool = true, mute: Bool = true) throws {
        let processes = Self.processes()
        guard !requireRunningProcess || !processes.isEmpty else {
            throw AudioFailure(operation: .errorChromeWaiting, code: -2)
        }
        let description = CATapDescription(stereoMixdownOfProcesses: processes)
        description.name = "Switchboard · Chrome"
        description.isPrivate = true
        description.muteBehavior = mute ? .mutedWhenTapped : .unmuted
        description.isProcessRestoreEnabled = true
        description.bundleIDs = Array(
            Set(
                ["com.google.Chrome", "com.google.Chrome.helper"]
                    + processes.map { AudioDevices.string($0, kAudioProcessPropertyBundleID) }))
        var status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else {
            throw AudioFailure(operation: .errorChromePermission, code: status)
        }
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Switchboard private Chrome tap",
            kAudioAggregateDeviceUIDKey: "com.switchboard.main.tap.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true,
                ]
            ],
        ]
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &deviceID)
        guard status == noErr else {
            stop()
            throw AudioFailure(operation: .errorChromeDevice, code: status)
        }
        members = Set(processes)
    }
    func membershipChanged() -> Bool { Set(Self.processes()) != members }
    func stop() {
        if deviceID != 0 {
            AudioHardwareDestroyAggregateDevice(deviceID)
            deviceID = 0
        }
        if tapID != 0 {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = 0
        }
        members.removeAll()
    }
    deinit { stop() }
}
