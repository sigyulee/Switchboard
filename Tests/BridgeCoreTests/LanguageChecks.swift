import BridgeCore
import Foundation

struct LanguageChecks {
    func firstLaunchRequiresChoiceAndSavesIt() throws {
        let name = "SwitchboardTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        try expect(ApplicationLanguage.saved(in: defaults) == nil)
        defaults.set("unsupported", forKey: "applicationLanguage")
        try expect(ApplicationLanguage.saved(in: defaults) == nil)
        ApplicationLanguage.korean.save(in: defaults)
        try expect(ApplicationLanguage.saved(in: defaults) == .korean)
        try expect(defaults.stringArray(forKey: "AppleLanguages") == ["ko"])
        ApplicationLanguage.english.save(in: defaults)
        try expect(ApplicationLanguage.saved(in: defaults) == .english)
    }

    func migrationPreservesChoicesWithoutCopyingPermissions() throws {
        let name = "SwitchboardTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(false, forKey: "speakerFallback")
        PreferenceMigration.apply(
            to: defaults,
            legacy: [
                "monitorUID": "headphones", "speakerFallback": true,
                "captureAccessBuild": "old-code-hash", "automaticRecording": true,
            ], recordingDirectory: URL(fileURLWithPath: "/tmp/existing-recordings"))
        try expect(defaults.string(forKey: "monitorUID") == "headphones")
        try expect(!defaults.bool(forKey: "speakerFallback"))
        try expect(defaults.object(forKey: "captureAccessBuild") == nil)
        try expect(defaults.object(forKey: "automaticRecording") == nil)
        try expect(ApplicationLanguage.saved(in: defaults) == nil)
        try expect(defaults.string(forKey: "recordingRoot") == "/tmp/existing-recordings")
        PreferenceMigration.apply(to: defaults, legacy: ["monitorUID": "different"], recordingDirectory: nil)
        try expect(defaults.string(forKey: "monitorUID") == "headphones")
    }
}
