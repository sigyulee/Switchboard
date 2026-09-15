import AppKit
import SwiftUI

struct SplitMenuOption {
    let id: String
    let title: String
    let selected: Bool
    let action: () -> Void
}

struct SplitMenu: NSViewRepresentable {
    @Environment(\.isEnabled) private var enabled
    let label: String
    let side: CGFloat
    let pointSize: CGFloat
    let options: [SplitMenuOption]

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> SplitMenuControl {
        let view = SplitMenuControl(frame: .zero, pullsDown: true)
        view.cell = SplitMenuCell(textCell: "", pullsDown: true)
        view.isBordered = false
        view.focusRingType = .none
        context.coordinator.view = view
        return view
    }

    func updateNSView(_ view: SplitMenuControl, context: Context) {
        view.side = side
        view.isEnabled = enabled
        if !enabled && view.menuIsOpen { view.menu?.cancelTracking() }
        view.setAccessibilityLabel(label)
        view.toolTip = label
        context.coordinator.options = options
        context.coordinator.label = label
        context.coordinator.pointSize = pointSize
        context.coordinator.updateMenu()
        view.needsDisplay = true
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SplitMenuControl, context: Context) -> CGSize? {
        CGSize(width: side, height: side)
    }

    static func dismantleNSView(_ view: SplitMenuControl, coordinator: Coordinator) {
        view.menu?.delegate = nil
        view.menu?.cancelTracking()
        view.menu = nil
        coordinator.invalidate()
    }

    @MainActor final class Coordinator: NSObject, NSMenuDelegate {
        weak var view: SplitMenuControl?
        var options: [SplitMenuOption] = []
        var label = ""
        var pointSize: CGFloat = 14
        private var descriptors: [String] = []
        private var closingMenu = false
        private var updateTask: Task<Void, Never>?

        func invalidate() {
            updateTask?.cancel()
            updateTask = nil
            closingMenu = false
            descriptors = []
            view = nil
            options = []
        }

        func updateMenu() {
            guard let view, !view.menuIsOpen, !closingMenu else { return }
            let next =
                [label, String(describing: pointSize)]
                + options.map { "\($0.id)|\($0.title)|\($0.selected)" }
            guard descriptors != next else { return }
            descriptors = next
            let menu = NSMenu(title: label)
            menu.autoenablesItems = false
            menu.font = .systemFont(ofSize: pointSize)
            // A pull-down button uses its first item as its label, outside the menu.
            menu.addItem(withTitle: label, action: nil, keyEquivalent: "")
            for option in options {
                let item = NSMenuItem(
                    title: option.title, action: #selector(selectOption(_:)), keyEquivalent: "")
                item.representedObject = option.id
                item.target = self
                item.state = option.selected ? .on : .off
                menu.addItem(item)
            }
            view.menu = menu
            menu.delegate = self
        }

        @objc private func selectOption(_ sender: NSMenuItem) {
            guard let view, view.isEnabled, let id = sender.representedObject as? String else { return }
            options.first { $0.id == id }?.action()
        }

        func menuWillOpen(_ menu: NSMenu) {
            view?.menuIsOpen = true
            view?.needsDisplay = true
        }

        func menuDidClose(_ menu: NSMenu) {
            view?.menuIsOpen = false
            view?.needsDisplay = true
            // AppKit forbids structural menu changes inside its tracking callbacks.
            closingMenu = true
            updateTask?.cancel()
            updateTask = Task { @MainActor [weak self] in
                await Task.yield()
                guard !Task.isCancelled, let self else { return }
                closingMenu = false
                updateTask = nil
                updateMenu()
            }
        }
    }
}

final class SplitMenuControl: NSPopUpButton {
    var side: CGFloat = 44 {
        didSet { if side != oldValue { invalidateIntrinsicContentSize() } }
    }
    var menuIsOpen = false
    override var intrinsicContentSize: NSSize { NSSize(width: side, height: side) }
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets() }
}

final class SplitMenuCell: NSPopUpButtonCell {
    override func draw(withFrame frame: NSRect, in controlView: NSView) {
        guard let control = controlView as? SplitMenuControl else { return }
        NSColor.separatorColor.setFill()
        NSRect(x: frame.minX, y: frame.minY + 10, width: 1, height: max(0, frame.height - 20)).fill()

        let scale = frame.height / 44
        let sign: CGFloat = controlView.isFlipped ? 1 : -1
        let chevron = NSBezierPath()
        chevron.move(to: NSPoint(x: frame.midX - 5 * scale, y: frame.midY - 2.5 * scale * sign))
        chevron.line(to: NSPoint(x: frame.midX, y: frame.midY + 2.5 * scale * sign))
        chevron.line(to: NSPoint(x: frame.midX + 5 * scale, y: frame.midY - 2.5 * scale * sign))
        chevron.lineWidth = 1.7 * scale
        chevron.lineCapStyle = .round
        chevron.lineJoinStyle = .round
        (control.isEnabled ? NSColor.labelColor : NSColor.tertiaryLabelColor).setStroke()
        chevron.stroke()
    }
}
