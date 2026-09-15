import AppKit
import BridgeCore
import CoreAudio
import Darwin

struct AppAudioTarget: Equatable, Sendable {
    let application: ApplicationIdentity
    let processes: [AudioObjectID]
}

@MainActor enum ApplicationCatalog {
    private static let suggestions: [(identifier: String, forAgent: Bool, fallbackPaths: [String])] = [
        ("com.openai.codex", true, ["/Applications/ChatGPT.app"]),
        ("com.google.Chrome", true, ["/Applications/Google Chrome.app"]),
        ("com.apple.mobilephone", false, ["/System/Applications/Phone.app"]),
        ("com.hnc.Discord", false, ["/Applications/Discord.app"]),
    ]

    static func identity(at url: URL) -> ApplicationIdentity? {
        guard let bundle = Bundle(url: url), let identifier = bundle.bundleIdentifier,
            identifier != Bundle.main.bundleIdentifier
        else { return nil }
        let name =
            (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        return try? ApplicationIdentity(bundleIdentifier: identifier, bundleURL: url, name: name)
    }

    static func installed(_ identifier: String) -> ApplicationIdentity? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier).flatMap {
            identity(at: $0, matching: identifier)
        }
    }

    static func identity(at url: URL, matching identifier: String) -> ApplicationIdentity? {
        guard let application = identity(at: url), application.id == identifier else { return nil }
        return application
    }

    static func isSuggested(_ application: ApplicationIdentity, forAgent: Bool) -> Bool {
        guard
            isUserFacing(application)
                && suggestions.contains(where: { $0.identifier == application.id && $0.forAgent == forAgent })
        else { return false }
        guard application.id == "com.openai.codex" else { return true }
        // Current ChatGPT and older Codex installations share this identifier.
        // Require bundle metadata; a renamed .app or saved picker label is insufficient.
        guard let bundle = Bundle(url: application.bundleURL), bundle.bundleIdentifier == application.id,
            bundle.object(forInfoDictionaryKey: "CFBundleExecutable") as? String == "ChatGPT"
        else { return false }
        let name =
            (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
        return name == "ChatGPT"
    }

    static func choices(including selected: [ApplicationIdentity]) -> [ApplicationIdentity] {
        choices(including: selected) { identifier, fallbackPaths in
            let registered = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier)
            return [registered].compactMap { $0 } + fallbackPaths.map { URL(fileURLWithPath: $0) }
        }
    }

    static func choices(
        including selected: [ApplicationIdentity],
        applicationURLs: (_ identifier: String, _ fallbackPaths: [String]) -> [URL]
    ) -> [ApplicationIdentity] {
        let knownInstalled = suggestions.compactMap { suggestion -> ApplicationIdentity? in
            // Registered discovery can be unavailable. A filename alone never establishes identity.
            applicationURLs(suggestion.identifier, suggestion.fallbackPaths).lazy.compactMap {
                identity(at: $0, matching: suggestion.identifier)
            }.first { isSuggested($0, forAgent: suggestion.forAgent) }
        }
        return choices(installed: knownInstalled, including: selected)
    }

    static func choices(
        installed: [ApplicationIdentity], including selected: [ApplicationIdentity]
    ) -> [ApplicationIdentity] {
        let candidates = selected + installed.filter(isSuggestedForEitherRole)
        var ids = Set<String>()
        return candidates.filter { ids.insert($0.id).inserted }.sorted {
            let leftSuggested = isSuggestedForEitherRole($0)
            let rightSuggested = isSuggestedForEitherRole($1)
            if leftSuggested != rightSuggested { return leftSuggested }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private static func isSuggestedForEitherRole(_ application: ApplicationIdentity) -> Bool {
        isSuggested(application, forAgent: true) || isSuggested(application, forAgent: false)
    }

    private static func isUserFacing(_ application: ApplicationIdentity) -> Bool {
        let url = application.bundleURL
        guard !url.path.hasPrefix("/System/Library/") else { return false }
        // Embedded application bundles are helpers, even when their activation
        // policy is regular. This controls picker presentation only.
        return !url.pathComponents.dropLast().contains {
            ["app", "appex", "xpc", "framework", "bundle"].contains(
                ($0 as NSString).pathExtension.lowercased())
        }
    }

    static func isRunning(_ application: ApplicationIdentity) -> Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == application.id
                && $0.executableURL.map(application.owns) == true
        }
    }

    static func audioTarget(for application: ApplicationIdentity) -> AppAudioTarget {
        var processes: [AudioObjectID] = []
        for object in AudioDevices.objects(AudioDevices.system, kAudioHardwarePropertyProcessObjectList) {
            let pid = AudioDevices.scalar(object, kAudioProcessPropertyPID, initial: pid_t(0))
            guard pid > 0, let executable = executableURL(pid: pid),
                application.owns(executableURL: executable)
            else { continue }
            processes.append(object)
        }
        return AppAudioTarget(application: application, processes: processes.sorted())
    }

    private static func executableURL(pid: pid_t) -> URL? {
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let count = path.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
        guard count > 0 else { return nil }
        return path.withUnsafeBufferPointer { buffer in
            buffer.baseAddress.map { URL(fileURLWithPath: String(cString: $0)) }
        }
    }
}
