import AppKit

@MainActor final class StatusBarController: NSObject, NSMenuDelegate {
    private let item: NSStatusItem
    private let menu = NSMenu()
    private weak var model: AppModel?
    private var strings: AppStrings { model?.strings ?? AppStrings(language: .english) }
    private var displayedSymbol = "waveform"

    init(model: AppModel) {
        self.model = model
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        item.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Switchboard")
        item.button?.toolTip = "Switchboard"
        menu.delegate = self
        menu.font = .systemFont(ofSize: 15)
        item.menu = menu
        NotificationCenter.default.addObserver(
            self, selector: #selector(dismissMenu), name: NSApplication.didResignActiveNotification,
            object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(workspaceChanged(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)
    }

    func refresh() {
        guard let model else { return }
        let symbol = model.isRecording ? "record.circle.fill" : "waveform"
        if displayedSymbol != symbol {
            item.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Switchboard")
            displayedSymbol = symbol
        }
        let toolTip =
            model.isRecording
            ? strings(.statusRecording, durationText(model.audio.recordedSeconds))
            : "Switchboard · \(model.statusTitle)"
        if item.button?.toolTip != toolTip { item.button?.toolTip = toolTip }
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let model else { return }
        menu.removeAllItems()
        let status = NSMenuItem(
            title: model.isRecording
                ? strings(.statusRecording, durationText(model.audio.recordedSeconds)) : model.statusTitle,
            action: nil,
            keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        add(strings(.menuOpen), action: #selector(showWindow))
        if model.isRecording { add(strings(.actionStopRecording), action: #selector(stopRecording)) }
        menu.addItem(.separator())
        add(model.suspended ? strings(.actionResume) : strings(.menuPause), action: #selector(toggleStandby))
        menu.addItem(.separator())
        add(strings(.menuQuit), action: #selector(quit))
    }
    private func add(_ title: String, action: Selector) {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
        entry.target = self
        menu.addItem(entry)
    }
    @objc private func dismissMenu() { menu.cancelTracking() }
    @objc private func workspaceChanged(_ notification: Notification) {
        guard
            let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication,
            application.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { return }
        dismissMenu()
    }
    @objc private func showWindow() {
        dismissMenu()
        if let window = NSApplication.shared.windows.first(where: { $0.identifier?.rawValue == "main" }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            model?.openMainWindow?()
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    @objc private func stopRecording() { Task { await model?.stopRecording() } }
    @objc private func toggleStandby() {
        guard let model else { return }
        if model.suspended { model.resume() } else { Task { await model.pause() } }
    }
    @objc private func quit() { NSApplication.shared.terminate(nil) }
}
