import BridgeCore
import Foundation

struct MonitorPolicyChecks {
    func fallbackOnlyWithConsentAndReturnsToPreferred() throws {
        try expect(
            MonitorPolicy.destination(preferredAvailable: false, builtInAvailable: true, fallback: false)
                == .unavailable)
        try expect(
            MonitorPolicy.destination(preferredAvailable: false, builtInAvailable: true, fallback: true)
                == .builtIn)
        try expect(
            MonitorPolicy.destination(preferredAvailable: true, builtInAvailable: true, fallback: true)
                == .preferred)
    }
}
