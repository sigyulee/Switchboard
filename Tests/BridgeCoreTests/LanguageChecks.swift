import BridgeCore
import Foundation

struct LanguageChecks {
    func savedRoutesIgnoreRetiredConfirmation() throws {
        let agent = try ApplicationIdentity(
            bundleIdentifier: "example.agent", bundleURL: URL(fileURLWithPath: "/tmp/Agent.app"),
            name: "Agent")
        let caller = try ApplicationIdentity(
            bundleIdentifier: "example.caller", bundleURL: URL(fileURLWithPath: "/tmp/Caller.app"),
            name: "Caller")
        let expected = try RouteProfile(agent: agent, caller: caller)
        var old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(expected)) as! [String: Any]
        old["callerDevicesConfirmed"] = false
        let restored = try JSONDecoder().decode(
            RouteProfile.self, from: JSONSerialization.data(withJSONObject: old))
        try expect(restored == expected)
    }

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

}
