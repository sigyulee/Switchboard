import BridgeCore
import Foundation

/// Persistent identifiers from the local prototype, kept only for a lossless upgrade.
enum LegacyInstallation {
    static let bundleIdentifier = "local.mouthinhands.app"

    static func migratePreferences(_ defaults: UserDefaults) {
        let music = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first
        let previous = music?.appendingPathComponent("손손이음센터/Recordings")
        let existing = previous.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        PreferenceMigration.apply(
            to: defaults,
            legacy: defaults.persistentDomain(forName: bundleIdentifier) ?? [:], recordingDirectory: existing)
    }
}
