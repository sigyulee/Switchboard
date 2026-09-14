public enum MonitorDestination: Equatable, Sendable { case preferred, builtIn, unavailable }
public enum MonitorPolicy {
    public static func destination(preferredAvailable: Bool, builtInAvailable: Bool, fallback: Bool)
        -> MonitorDestination
    {
        if preferredAvailable { return .preferred }
        return fallback && builtInAvailable ? .builtIn : .unavailable
    }
}

public struct InputLease: Codable, Sendable {
    public let ownedUID: String
    public private(set) var restorationUID: String
    public init(ownedUID: String, previousUID: String) {
        self.ownedUID = ownedUID
        self.restorationUID = previousUID
    }
    public mutating func observed(_ uid: String) -> Bool {
        guard !uid.isEmpty, uid != ownedUID else { return false }
        restorationUID = uid
        return true
    }
    /// Transfer an owned default-input change to a replacement bridge device.
    /// An already selected new target belongs to the user, so it needs no lease.
    public func retargeted(to uid: String, currentUID: String) -> Self? {
        guard !uid.isEmpty, !currentUID.isEmpty else { return nil }
        if currentUID == uid { return ownedUID == uid ? self : nil }
        return Self(ownedUID: uid, previousUID: currentUID == ownedUID ? restorationUID : currentUID)
    }

    public func restoration(currentUID: String) -> String? {
        guard currentUID == ownedUID, restorationUID != ownedUID, !restorationUID.isEmpty else { return nil }
        return restorationUID
    }
}
