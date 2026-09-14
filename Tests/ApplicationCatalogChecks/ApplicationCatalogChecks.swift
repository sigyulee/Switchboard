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
            try automaticChoicesContainOnlySupportedInstalledApplications()
            try selectionsAndKnownInstalledAppsSurviveWithoutRunningProcesses()
            try selectedIdentityWinsOverAnotherInstallation()
            try filteredHelpersRemainOwnedByTheirApplication()
            try suggestionsMatchTheirSupportedRole()
            try canonicalFallbackRequiresTheExpectedIdentifier()
            print("Application catalog checks passed: 6 checks; no workspace or audio access.")
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

    static func automaticChoicesContainOnlySupportedInstalledApplications() throws {
        let fixtures: [(String, String, String)] = [
            ("com.mitchellh.ghostty", "/Applications/Ghostty.app", "Ghostty"),
            ("com.apple.Safari", "/Applications/Safari.app", "Safari"),
            ("com.openai.codex", "/Applications/ChatGPT.app", "ChatGPT"),
            ("com.apple.FaceTime", "/System/Applications/FaceTime.app", "FaceTime"),
            ("com.hnc.Discord", "/Applications/Discord.app", "Discord"),
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
        let choices = ApplicationCatalog.choices(
            installed: unverified + [chrome, chat, phone], including: [])
        try require(
            choices.map(\.id) == ["com.openai.chat", "com.google.Chrome", "com.apple.mobilephone"],
            "Automatic choices must exclude Ghostty and other unverified regular applications")
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

    static func suggestionsMatchTheirSupportedRole() throws {
        for (identifier, path, agent, caller) in [
            ("com.openai.chat", "/Applications/ChatGPT Classic.app", true, false),
            ("com.google.Chrome", "/Applications/Google Chrome.app", true, false),
            ("com.apple.mobilephone", "/System/Applications/Phone.app", false, true),
            ("com.openai.codex", "/Applications/ChatGPT.app", false, false),
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
