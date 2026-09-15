import AppKit
import BridgeCore
import CoreAudio
import Foundation

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

private func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw CheckFailure(description: message) }
}

// Picker checks must never enumerate audio processes or access an audio device.
enum AudioDevices {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    static func objects(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        fatalError("Application picker checks must not enumerate audio processes")
    }
    static func scalar<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, initial: T) -> T {
        fatalError("Application picker checks must not read audio properties")
    }
}

@MainActor @main private struct ApplicationCatalogChecks {
    static func main() {
        do {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let chatGPT = try bundle(
                at: root.appendingPathComponent("Current ChatGPT.app"), identifier: "com.openai.codex",
                name: "ChatGPT", displayName: "ChatGPT", executable: "ChatGPT")
            try automaticChoicesContainOnlySupportedInstalledApplications(chatGPT: chatGPT)
            try selectionsAndKnownInstalledAppsSurviveWithoutRunningProcesses()
            try selectedIdentityWinsOverAnotherInstallation()
            try filteredHelpersRemainOwnedByTheirApplication()
            try suggestionsMatchTheirSupportedRole(chatGPT: chatGPT)
            try canonicalFallbackRequiresTheExpectedIdentifier()
            try chatGPTSuggestionRequiresBundleMetadata(in: root, chatGPT: chatGPT)
            try selectedLegacyApplicationsAreNotReplaced(in: root, chatGPT: chatGPT)
            try registeredDiscoveryRefreshesCuratedChoices(in: root, chatGPT: chatGPT)
            print("Application catalog checks passed: 9 checks; no workspace or audio access.")
        } catch {
            FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
            exit(1)
        }
    }

    static func application(_ identifier: String, _ path: String, _ name: String) throws
        -> ApplicationIdentity
    {
        try ApplicationIdentity(
            bundleIdentifier: identifier, bundleURL: URL(fileURLWithPath: path), name: name)
    }

    static func bundle(
        at url: URL, identifier: String, name: String?, displayName: String? = nil,
        executable: String
    ) throws -> ApplicationIdentity {
        let contents = url.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        var info = [
            "CFBundleIdentifier": identifier, "CFBundlePackageType": "APPL",
            "CFBundleExecutable": executable,
        ]
        info["CFBundleName"] = name
        info["CFBundleDisplayName"] = displayName
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        guard let identity = ApplicationCatalog.identity(at: url) else {
            throw CheckFailure(description: "Fixture bundle identity was not recognized")
        }
        return identity
    }

    static func automaticChoicesContainOnlySupportedInstalledApplications(chatGPT: ApplicationIdentity) throws
    {
        let fixtures: [(String, String, String)] = [
            ("com.mitchellh.ghostty", "/Applications/Ghostty.app", "Ghostty"),
            ("com.apple.Safari", "/Applications/Safari.app", "Safari"),
            ("com.openai.codex", "/tmp/catalog-user/ChatGPT.app", "ChatGPT"),
            ("com.apple.FaceTime", "/System/Applications/FaceTime.app", "FaceTime"),
            ("com.hnc.DiscordCanary", "/Applications/Discord Canary.app", "Discord Canary"),
            ("local", "/tmp/catalog-user/Applications/Local.app", "Local"),
            ("helper", "/Applications/Browser.app/Contents/Frameworks/Helper.app", "Helper"),
            ("background", "/Applications/Background.app", "Background"),
            ("dock", "/System/Library/CoreServices/Dock.app", "Dock"),
            ("plugin", "/Library/Example.appex/Contents/Helper.app", "Plugin helper"),
            ("xpc", "/Library/Example.xpc/Contents/Helper.app", "XPC helper"),
            ("framework", "/Library/Example.framework/Resources/Helper.app", "Framework helper"),
            ("bundle", "/Library/Example.bundle/Contents/Helper.app", "Bundle helper"),
        ]
        let unverified = try fixtures.map { identifier, path, name in
            try application(identifier, path, name)
        }
        let chrome = try application("com.google.Chrome", "/Applications/Google Chrome.app", "Google Chrome")
        let chat = try application("com.openai.chat", "/Applications/ChatGPT Classic.app", "ChatGPT Classic")
        let phone = try application("com.apple.mobilephone", "/System/Applications/Phone.app", "Phone")
        let discord = try application("com.hnc.Discord", "/Applications/Discord.app", "Discord")
        let choices = ApplicationCatalog.choices(
            installed: unverified + [chrome, chat, phone, chatGPT, discord], including: [])
        try require(
            choices == [chatGPT, discord, chrome, phone],
            "Automatic choices must include current ChatGPT and Discord, excluding Classic and unsupported apps"
        )
    }

    static func selectionsAndKnownInstalledAppsSurviveWithoutRunningProcesses() throws {
        let agent = try application("agent", "/tmp/catalog-user/Tools/Agent.app", "Agent")
        let caller = try application("caller", "/tmp/catalog-user/Tools/Caller.app", "Caller")
        let browser = try application("com.google.Chrome", "/Applications/Google Chrome.app", "Google Chrome")
        let choices = ApplicationCatalog.choices(
            installed: [browser], including: [agent, caller])
        try require(
            choices.map(\.id) == ["com.google.Chrome", "agent", "caller"],
            "Selections and curated installed apps must remain visible when absent from automatic choices")
        let custom = try application("custom", "/System/Library/CoreServices/Custom.app", "Custom")
        let chosen = ApplicationCatalog.choices(installed: [], including: [custom])
        try require(chosen == [custom], "Explicit selections must survive automatic path filtering")
        let ghostty = try application("com.mitchellh.ghostty", "/Applications/Ghostty.app", "Ghostty")
        let manual = ApplicationCatalog.choices(installed: [ghostty, browser], including: [ghostty])
        try require(
            manual == [browser, ghostty], "An explicit custom selection must follow supported suggestions")
        try require(
            !ApplicationCatalog.isSuggested(ghostty, forAgent: true)
                && !ApplicationCatalog.isSuggested(ghostty, forAgent: false),
            "An explicit custom selection must not become a recommended application")
    }

    static func selectedIdentityWinsOverAnotherInstallation() throws {
        let old = try application("com.google.Chrome", "/Applications/Browser.app", "Browser")
        let selected = try application("com.google.Chrome", "/tmp/catalog-user/Tools/Browser.app", "Browser")
        let choices = ApplicationCatalog.choices(
            installed: [old], including: [selected])
        try require(choices.count == 1, "Duplicate bundle identifiers must produce one choice")
        try require(
            choices.first?.bundleURL.path == "/tmp/catalog-user/Tools/Browser.app",
            "Discovery must not replace the selected bundle's executable root with another installation")
        try require(
            choices.first?.owns(
                executableURL: URL(fileURLWithPath: "/Applications/Browser.app/Contents/MacOS/Browser"))
                == false,
            "The selected candidate must not capture the other installation with the same bundle identifier")
    }

    static func filteredHelpersRemainOwnedByTheirApplication() throws {
        let browser = try application("com.google.Chrome", "/Applications/Browser.app", "Browser")
        let helper = try application(
            "helper", "/Applications/Browser.app/Contents/Frameworks/Helper.app", "Helper")
        let choices = ApplicationCatalog.choices(
            installed: [browser, helper], including: [])
        try require(
            choices.map(\.id) == ["com.google.Chrome"],
            "Nested helper must not become a separate picker choice")
        try require(
            browser.owns(executableURL: helper.bundleURL.appendingPathComponent("Contents/MacOS/Helper")),
            "Filtering picker choices must preserve capture ownership of nested helper executables")
        try require(
            !browser.owns(
                executableURL: URL(fileURLWithPath: "/Applications/Browser.app.fake/Contents/Helper")),
            "Similar path prefixes must remain outside the selected executable root")
    }

    static func suggestionsMatchTheirSupportedRole(chatGPT: ApplicationIdentity) throws {
        try require(
            ApplicationCatalog.isSuggested(chatGPT, forAgent: true)
                && !ApplicationCatalog.isSuggested(chatGPT, forAgent: false),
            "Current ChatGPT must be suggested only for Agent")
        for (identifier, path, agent, caller) in [
            ("com.openai.chat", "/Applications/ChatGPT Classic.app", false, false),
            ("com.google.Chrome", "/Applications/Google Chrome.app", true, false),
            ("com.apple.mobilephone", "/System/Applications/Phone.app", false, true),
            ("com.hnc.Discord", "/Applications/Discord.app", false, true),
            ("com.hnc.DiscordCanary", "/Applications/Discord Canary.app", false, false),
            ("com.openai.codex", "/tmp/catalog-user/ChatGPT.app", false, false),
            ("com.google.Chrome", "/Applications/Parent.app/Contents/Helper.app", false, false),
            ("com.apple.mobilephone", "/System/Library/Services/Phone.app", false, false),
        ] {
            let candidate = try application(identifier, path, "Fixture")
            try require(
                ApplicationCatalog.isSuggested(candidate, forAgent: true) == agent,
                "Agent suggestions admitted an unsupported identity or path")
            try require(
                ApplicationCatalog.isSuggested(candidate, forAgent: false) == caller,
                "Caller suggestions admitted an unsupported identity or path")
        }
    }

    static func chatGPTSuggestionRequiresBundleMetadata(in root: URL, chatGPT: ApplicationIdentity) throws {
        let fixtures: [(String, String, String?, String?, String)] = [
            ("renamed/ChatGPT.app", "com.openai.codex", "Codex", "Codex", "Codex"),
            ("filename-only/ChatGPT.app", "com.openai.codex", nil, nil, "ChatGPT"),
            ("wrong-executable/ChatGPT.app", "com.openai.codex", "ChatGPT", "ChatGPT", "Codex"),
            ("classic/ChatGPT.app", "com.openai.chat", "ChatGPT", "ChatGPT", "ChatGPT"),
            ("wrong-identifier/ChatGPT.app", "example.chat", "ChatGPT", "ChatGPT", "ChatGPT"),
        ]
        for (path, identifier, name, displayName, executable) in fixtures {
            let candidate = try bundle(
                at: root.appendingPathComponent(path), identifier: identifier, name: name,
                displayName: displayName, executable: executable)
            try require(
                !ApplicationCatalog.isSuggested(candidate, forAgent: true),
                "ChatGPT suggestion accepted a filename, Classic, or legacy Codex identity: \(path)")
            let savedLabel = try application("com.openai.codex", candidate.bundleURL.path, "ChatGPT")
            try require(
                !ApplicationCatalog.isSuggested(savedLabel, forAgent: true),
                "A saved ChatGPT label must not override the bundle's actual identity: \(path)")
        }
        try require(
            ApplicationCatalog.isSuggested(chatGPT, forAgent: true),
            "A renamed installation with current ChatGPT bundle metadata must remain suggested")
    }

    static func selectedLegacyApplicationsAreNotReplaced(in root: URL, chatGPT: ApplicationIdentity) throws {
        let codex = try bundle(
            at: root.appendingPathComponent("Legacy Codex.app"), identifier: "com.openai.codex",
            name: "Codex", executable: "Codex")
        let classic = try application(
            "com.openai.chat", "/Applications/ChatGPT Classic.app", "ChatGPT Classic")
        let choices = ApplicationCatalog.choices(installed: [chatGPT, classic], including: [codex, classic])
        try require(
            choices == [classic, codex],
            "Discovery must preserve explicit Classic and Codex selections without replacing a shared identifier"
        )
        try require(
            !codex.owns(executableURL: chatGPT.bundleURL.appendingPathComponent("Contents/MacOS/ChatGPT")),
            "A legacy selection must not capture the current ChatGPT installation with the same identifier")
    }

    static func registeredDiscoveryRefreshesCuratedChoices(in root: URL, chatGPT: ApplicationIdentity) throws
    {
        let discord = try bundle(
            at: root.appendingPathComponent("User Applications/Discord.app"), identifier: "com.hnc.Discord",
            name: "Discord", executable: "Discord")
        let codex = try bundle(
            at: root.appendingPathComponent("Registered Codex.app"), identifier: "com.openai.codex",
            name: "Codex", executable: "Codex")
        let classic = try bundle(
            at: root.appendingPathComponent("Registered Classic.app"), identifier: "com.openai.chat",
            name: "ChatGPT Classic", executable: "ChatGPT")
        var registered: [String: URL] = [:]
        var fallback: [String: URL] = [:]
        let discover: (String, [String]) -> [URL] = { identifier, paths in
            [registered[identifier]].compactMap { $0 } + paths.compactMap { fallback[$0] }
        }
        try require(
            ApplicationCatalog.choices(including: [], applicationURLs: discover).isEmpty,
            "Unresolved applications must not become picker choices")
        registered = ["com.openai.codex": chatGPT.bundleURL, "com.hnc.Discord": discord.bundleURL]
        try require(
            ApplicationCatalog.choices(including: [], applicationURLs: discover) == [chatGPT, discord],
            "The next catalog refresh must discover registered ChatGPT and Discord outside canonical paths")

        registered = ["com.openai.codex": codex.bundleURL]
        fallback = ["/Applications/ChatGPT.app": chatGPT.bundleURL]
        try require(
            ApplicationCatalog.choices(including: [], applicationURLs: discover) == [chatGPT],
            "Registered legacy Codex must not prevent fallback discovery of current ChatGPT")
        registered = ["com.openai.codex": classic.bundleURL]
        try require(
            ApplicationCatalog.choices(including: [discord], applicationURLs: discover) == [
                chatGPT, discord,
            ],
            "Mismatched registered identities must use verified fallback while explicit selections survive")
        registered = [:]
        fallback = ["/Applications/ChatGPT Classic.app": classic.bundleURL]
        try require(
            ApplicationCatalog.choices(including: [], applicationURLs: discover).isEmpty,
            "Classic alone must not be offered as the current ChatGPT application")
    }

    static func canonicalFallbackRequiresTheExpectedIdentifier() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let renamed = root.appendingPathComponent("ChatGPT.app", isDirectory: true)
        let classic = root.appendingPathComponent("ChatGPT Classic.app", isDirectory: true)
        for (url, identifier, name) in [
            (renamed, "com.openai.codex", "ChatGPT"),
            (classic, "com.openai.chat", "ChatGPT Classic"),
        ] {
            let contents = url.appendingPathComponent("Contents", isDirectory: true)
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(
                fromPropertyList: [
                    "CFBundleIdentifier": identifier, "CFBundleName": name, "CFBundlePackageType": "APPL",
                ], format: .xml, options: 0)
            try data.write(to: contents.appendingPathComponent("Info.plist"))
        }
        try require(
            ApplicationCatalog.identity(at: renamed, matching: "com.openai.chat") == nil,
            "A canonical filename admitted an application with a different bundle identifier")
        let alias = root.appendingPathComponent("Legacy alias.app")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: classic)
        guard let verified = ApplicationCatalog.identity(at: alias, matching: "com.openai.chat") else {
            throw CheckFailure(description: "A matching installed application was not recognized")
        }
        try require(verified.name == "ChatGPT Classic", "Discovery replaced the actual application's name")
        try require(
            verified.bundleURL == classic.standardizedFileURL.resolvingSymlinksInPath(),
            "Discovery did not preserve the canonical application bundle root")
    }
}
