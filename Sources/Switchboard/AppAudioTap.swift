import CoreAudio
import Foundation

final class AppAudioTap {
    private(set) var tapID: AudioObjectID = 0
    private(set) var deviceID: AudioDeviceID = 0
    let target: AppAudioTarget

    init(target: AppAudioTarget) { self.target = target }

    func start(requireRunningProcess: Bool = true, mute: Bool = true) throws {
        let processes = target.processes
        guard !requireRunningProcess || !processes.isEmpty else {
            throw AudioFailure(operation: .errorChromeWaiting, code: -2)
        }
        let description = ProcessTapConfiguration.make(
            processes: processes, name: "Switchboard · \(target.application.name)", mute: mute)
        var status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else {
            throw AudioFailure(operation: .errorChromePermission, code: status)
        }
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Switchboard private application tap",
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
    }
    func stop() {
        if deviceID != 0 {
            AudioHardwareDestroyAggregateDevice(deviceID)
            deviceID = 0
        }
        if tapID != 0 {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = 0
        }
    }
    deinit { stop() }
}
