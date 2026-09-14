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
