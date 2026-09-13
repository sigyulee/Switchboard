import AppKit
import BridgeCore
import CoreAudio
import Darwin

struct AppAudioTarget: Equatable, Sendable {
    let application: ApplicationIdentity
    let processes: [AudioObjectID]
}

@MainActor enum ApplicationCatalog {
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
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier).flatMap(identity)
    }

    static func choices(including selected: ApplicationIdentity?) -> [ApplicationIdentity] {
        var candidates = NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL }.compactMap(
            identity)
        for identifier in [
            "com.google.Chrome", "com.apple.Safari", "com.openai.chat", "com.apple.mobilephone",
            "com.apple.FaceTime", "com.hnc.Discord", "com.kakao.KakaoTalkMac", "ru.keepcoder.Telegram",
        ] {
            if let application = installed(identifier) { candidates.append(application) }
        }
        if let selected { candidates.append(selected) }
        var ids = Set<String>()
        return candidates.filter { ids.insert($0.id).inserted }.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
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
