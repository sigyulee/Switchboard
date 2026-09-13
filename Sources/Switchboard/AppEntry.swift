import AppKit
import SwiftUI

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?
    private var terminating = false
    private var statusBar: StatusBarController?
    func attach(_ model: AppModel) -> Bool {
        if let bundle = Bundle.main.bundleIdentifier {
            let running = [bundle, LegacyInstallation.bundleIdentifier].flatMap {
                NSRunningApplication.runningApplications(withBundleIdentifier: $0)
            }
            let first = running.min {
                let a = $0.launchDate ?? .distantPast
                let b = $1.launchDate ?? .distantPast
                return a == b ? $0.processIdentifier < $1.processIdentifier : a < b
            }
            if let first, first.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                NSApplication.shared.terminate(nil)
                return false
            }
        }
        self.model = model
        if statusBar == nil { statusBar = StatusBarController(model: model) }
        model.statusBarRefresh = { [weak self] in self?.statusBar?.refresh() }
        return true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateLater }
        terminating = true
        Task {
            await model?.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main struct SwitchboardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ViewState private var model = AppModel(
        preview: CommandLine.arguments.contains("--preview")
            || Bundle.main.object(forInfoDictionaryKey: "SwitchboardPreview") as? Bool == true)
    private var strings: AppStrings { model.strings }
    var body: some Scene {
        Window("Switchboard", id: "main") {
            RootView(model: model)
                .environment(\.appStrings, model.strings)
                .environment(\.locale, model.strings.locale)
                .task { if delegate.attach(model) { model.boot() } }
        }
        .defaultSize(width: 780, height: 720)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .newItem) {
                Button(model.isRecording ? strings(.actionStopRecording) : strings(.actionStartRecording)) {
                    if model.isRecording {
                        Task { await model.stopRecording() }
                    } else {
                        model.startRecording()
                    }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(
                    model.preview || model.starting || model.pausing
                        || (!model.isRecording && (!model.audio.callerReady || !model.phoneRunning))
                )
            }
        }
        Settings {
            Group {
                if model.language == nil {
                    LanguageChoiceView(choose: model.chooseLanguage)
                } else {
                    SettingsView(model: model).frame(width: 540).padding(24)
                }
            }
            .environment(\.appStrings, model.strings)
            .environment(\.locale, model.strings.locale)
        }
    }
}

func durationText(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds < Double(Int.max), seconds >= 0 else { return "—" }
    let seconds = max(0, Int(seconds))
    return seconds >= 3600
        ? String(format: "%d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
        : String(format: "%02d:%02d", seconds / 60, seconds % 60)
}
