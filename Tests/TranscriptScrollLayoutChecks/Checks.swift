import AppKit
import BridgeCore
import Observation
import SwiftUI

struct ScrollTestStrings {
    func callAsFunction(_ key: TextKey, _ arguments: CVarArg...) -> String { key.rawValue }
}
private struct ScrollStringsKey: EnvironmentKey {
    static let defaultValue = ScrollTestStrings()
}
extension EnvironmentValues {
    var appStrings: ScrollTestStrings {
        get { self[ScrollStringsKey.self] }
        set { self[ScrollStringsKey.self] = newValue }
    }
}
func durationText(_ seconds: Double) -> String { String(format: "%.0f", seconds) }

@MainActor @Observable final class ScrollFixture {
    var entries: [TranscriptEntry] = []
    var tail = CGRect.null
    var processing = false
    let id = UUID()
    let find = AppFindController()
    func append() {
        let number = entries.count + 1
        entries.append(
            TranscriptEntry(
                side: .caller, startFrame: Int64(number) * 48_000,
                endFrame: Int64(number + 1) * 48_000,
                original: "Message \(number): " + String(repeating: "New conversation text. ", count: 6),
                isFinal: true))
    }
}
private struct ScrollFixtureView: View {
    let model: ScrollFixture
    var body: some View {
        TranscriptMessages(transcriptID: model.id, entries: model.entries, isProcessing: model.processing)
            .environment(model.find)
            .onPreferenceChange(TranscriptTailFrame.self) { frame in model.tail = frame }
    }
}

@main @MainActor struct ScrollLayoutChecks {
    static func settle(_ view: NSView) {
        let deadline = Date().addingTimeInterval(0.5)
        while Date() < deadline {
            view.layoutSubtreeIfNeeded()
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }
    static func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView, scroll.documentView != nil { return scroll }
        return view.subviews.lazy.compactMap { scrollView(in: $0) }.first
    }
    static func requireBottom(_ model: ScrollFixture, in view: NSView, _ reason: String) {
        let frame = model.tail
        precondition(!frame.isNull, "The latest message was not laid out")
        let availableHeight = view.bounds.height - (model.processing ? 56 : 0)
        let gap = availableHeight - frame.maxY
        precondition(gap >= -2 && gap <= 34, "\(reason): actual tail gap \(gap)")
    }
    static func main() {
        _ = NSApplication.shared
        let model = ScrollFixture()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 480),
            styleMask: [.borderless], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: ScrollFixtureView(model: model))
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 680, height: 480)
        settle(host)
        for _ in 0..<8 {
            model.append()
            settle(host)
            if model.entries.count >= 5 { requireBottom(model, in: host, "Growing initial transcript") }
        }
        for _ in 0..<4 {
            model.append()
            settle(host)
            requireBottom(model, in: host, "Appended message")
            model.entries[model.entries.count - 1].translation = String(
                repeating: "나중에 도착한 번역입니다. ", count: 25)
            model.entries[model.entries.count - 1].translationStatus = .translated
            settle(host)
            requireBottom(model, in: host, "Delayed translation")
        }
        for processing in [true, false] {
            model.processing = processing
            settle(host)
            requireBottom(model, in: host, "Processing footer transition")
            model.append()
            settle(host)
            requireBottom(model, in: host, "Message with processing footer")
        }
        print(
            "PASS live transcript stays at bottom after messages and delayed translations; no windows displayed."
        )
    }
}
