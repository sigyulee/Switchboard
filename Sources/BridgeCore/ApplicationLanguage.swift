import Foundation

public enum ApplicationLanguage: String, CaseIterable, Identifiable, Sendable {
    case english = "en"
    case korean = "ko"

    public var id: String { rawValue }
    public var nativeName: String { self == .english ? "English" : "한국어" }
    public var locale: Locale { Locale(identifier: rawValue) }

    public static func saved(in defaults: UserDefaults) -> Self? {
        defaults.string(forKey: "applicationLanguage").flatMap(Self.init(rawValue:))
    }

    public func save(in defaults: UserDefaults) {
        defaults.set(rawValue, forKey: "applicationLanguage")
        defaults.set([rawValue], forKey: "AppleLanguages")
    }
}

public enum PreferenceMigration {
    /// Copy only compatible user settings. Never inherit permission or removed feature state.
    public static func apply(to defaults: UserDefaults, legacy: [String: Any], recordingDirectory: URL?) {
        guard !defaults.bool(forKey: "legacyPreferencesMigrated") else { return }
        for key in ["monitorUID", "monitorName", "speakerFallback", "recordingRoot", "defaultInputLease"] {
            if defaults.object(forKey: key) == nil, let value = legacy[key] {
                defaults.set(value, forKey: key)
            }
        }
        if defaults.string(forKey: "recordingRoot") == nil, let recordingDirectory {
            defaults.set(recordingDirectory.path, forKey: "recordingRoot")
        }
        defaults.set(true, forKey: "legacyPreferencesMigrated")
    }
}
