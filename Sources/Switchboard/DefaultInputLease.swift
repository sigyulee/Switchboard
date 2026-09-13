import BridgeCore
import Foundation

@MainActor final class DefaultInputLease {
    private let key = "defaultInputLease"
    private var lease: InputLease?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key) {
            lease = try? JSONDecoder().decode(InputLease.self, from: data)
        }
    }
    func maintain(devices: [AudioDevice]) throws {
        guard let target = devices.first(where: { $0.uid == AudioDevices.callerUID && $0.alive }) else {
            return
        }
        let currentID = AudioDevices.defaultInput()
        guard let current = devices.first(where: { $0.id == currentID }) else { return }
        if lease == nil {
            guard current.uid != target.uid else { return }
            lease = InputLease(ownedUID: target.uid, previousUID: current.uid)
        } else if current.uid != target.uid {
            _ = lease?.observed(current.uid)
        }
        if let lease { defaults.set(try JSONEncoder().encode(lease), forKey: key) }
        if currentID != target.id { try AudioDevices.setDefaultInput(target.id) }
    }
    func restore(devices: [AudioDevice]) throws {
        guard let lease else { return }
        let current = devices.first { $0.id == AudioDevices.defaultInput() }
        guard let current else { throw AudioFailure(operation: .errorRestoreWait, code: -1) }
        if let uid = lease.restoration(currentUID: current.uid) {
            guard let target = devices.first(where: { $0.uid == uid && $0.alive }) else {
                throw AudioFailure(operation: .errorRestoreOriginal, code: -1)
            }
            try AudioDevices.setDefaultInput(target.id)
        }
        self.lease = nil
        defaults.removeObject(forKey: key)
    }
}
