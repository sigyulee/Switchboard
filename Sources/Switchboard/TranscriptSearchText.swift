import AppKit
import SwiftUI

/// Uses native text layout so find navigation can reveal a character range inside a long message.
struct TranscriptSearchText: NSViewRepresentable {
    let text: String
    let font: NSFont
    let secondary: Bool
    let matches: [TranscriptSearchMatch]
    let selected: TranscriptSearchMatch?
    let revealID: UUID?
    let focus: () -> Void

    func makeNSView(context: Context) -> TranscriptSearchTextView {
        let view = TranscriptSearchTextView()
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = false
        view.textContainer?.heightTracksTextView = false
        return view
    }

    func updateNSView(_ view: TranscriptSearchTextView, context: Context) {
        view.interaction = focus
        let value = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: font, .foregroundColor: secondary ? NSColor.secondaryLabelColor : .labelColor,
            ])
        for match in matches where Range(match.range, in: text) != nil {
            value.addAttributes(
                [
                    .backgroundColor: match == selected
                        ? NSColor.systemOrange.withAlphaComponent(0.65)
                        : NSColor.systemYellow.withAlphaComponent(0.35),
                    .foregroundColor: NSColor.labelColor,
                ], range: match.range)
        }
        if view.textStorage?.isEqual(to: value) != true { view.textStorage?.setAttributedString(value) }
        view.reveal(selected?.range, request: revealID)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: TranscriptSearchTextView, context: Context)
        -> CGSize?
    {
        guard let container = view.textContainer, let layout = view.layoutManager else { return nil }
        container.containerSize = NSSize(
            width: max(1, proposal.width ?? 500), height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        return CGSize(width: ceil(used.width), height: max(1, ceil(used.height)))
    }

    static func dismantleNSView(_ view: TranscriptSearchTextView, coordinator: ()) {
        view.cancelReveal()
        view.interaction = nil
    }
}

@MainActor final class TranscriptSearchTextView: NSTextView {
    var interaction: (() -> Void)?
    private var request: UUID?
    private var revealTask: Task<Void, Never>?

    override func mouseDown(with event: NSEvent) {
        interaction?()
        super.mouseDown(with: event)
    }

    func reveal(_ range: NSRange?, request: UUID?) {
        guard self.request != request else { return }
        self.request = request
        revealTask?.cancel()
        guard let range, let request else { return }
        revealTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self, self.request == request,
                Range(range, in: string) != nil
            else { return }
            if let textContainer { layoutManager?.ensureLayout(for: textContainer) }
            scrollRangeToVisible(range)
            revealTask = nil
        }
    }

    func cancelReveal() {
        revealTask?.cancel()
        revealTask = nil
    }
    deinit { revealTask?.cancel() }
}
