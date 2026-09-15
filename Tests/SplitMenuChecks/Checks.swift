import AppKit
import Darwin
import SwiftUI

@main @MainActor struct SplitMenuChecks {
    static func rendered(_ control: SplitMenuControl) -> NSBitmapImageRep {
        let image = NSImage(size: control.bounds.size)
        image.lockFocus()
        NSColor.clear.setFill()
        control.bounds.fill(using: .copy)
        control.cell!.draw(withFrame: control.bounds, in: control)
        image.unlockFocus()
        return NSBitmapImageRep(data: image.tiffRepresentation!)!
    }
    static func combinedControl() {
        let host = NSHostingView(
            rootView: SplitActionButton(
                title: "Play", systemImage: "play.fill", menuLabel: "Source tracks", action: {}, options: []
            ).environment(\.appTypography, AppTypography(textSize: .standard)))
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(
            contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        func control(in view: NSView) -> SplitMenuControl? {
            (view as? SplitMenuControl) ?? view.subviews.lazy.compactMap { control(in: $0) }.first
        }
        host.layoutSubtreeIfNeeded()
        let deadline = Date().addingTimeInterval(1)
        while control(in: host) == nil && Date() < deadline {
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
            host.layoutSubtreeIfNeeded()
        }
        guard let menu = control(in: host) else { fatalError("Combined button did not create a native menu") }
        print(
            "Combined menu frame=\(menu.frame), bounds=\(menu.bounds), alignment=\(menu.alignmentRectInsets), side=\(menu.side)"
        )
        fflush(stdout)
        precondition(
            abs(menu.frame.width - menu.side) < 0.5,
            "Native menu overhang shifts the highlight away from its allocated split boundary")
    }
    static func main() {
        _ = NSApplication.shared
        combinedControl()
        let control = SplitMenuControl(frame: NSRect(x: 0, y: 0, width: 44, height: 44), pullsDown: true)
        control.cell = SplitMenuCell(textCell: "", pullsDown: true)
        control.isBordered = false
        precondition(control.intrinsicContentSize == NSSize(width: 44, height: 44))
        let idle = rendered(control)
        precondition(
            idle.colorAt(x: 0, y: idle.pixelsHigh / 2)!.alphaComponent > 0.02,
            "The divider must occupy the first pixel at the native segment boundary")
        precondition(
            idle.colorAt(x: 4, y: idle.pixelsHigh / 2)!.alphaComponent < 0.02,
            "The idle segment must not have an extra inner highlight")
        control.menuIsOpen = true
        let pressed = rendered(control)
        precondition(
            pressed.colorAt(x: 1, y: 1)!.alphaComponent < 0.02,
            "An open dropdown must not highlight its background")
        control.menuIsOpen = false
        control.cell!.isHighlighted = true
        let highlighted = rendered(control)
        precondition(
            highlighted.colorAt(x: 4, y: highlighted.pixelsHigh / 2)!.alphaComponent < 0.02,
            "Native pressed feedback must not fill the dropdown background")
        control.isEnabled = false
        precondition(rendered(control).colorAt(x: 1, y: 1)!.alphaComponent < 0.02)
        control.isEnabled = true

        let coordinator = SplitMenu.Coordinator()
        coordinator.view = control
        coordinator.label = "Playback source"
        var selection = "mix"
        func options(_ selected: String) -> [SplitMenuOption] {
            ["mix", "caller", "agent"].map { id in
                SplitMenuOption(id: id, title: id, selected: selected == id, action: { selection = id })
            }
        }
        coordinator.options = options("mix")
        coordinator.updateMenu()
        let menu = control.menu!
        precondition(menu.items.count == 4 && menu.items[1].state == .on)
        coordinator.menuWillOpen(menu)
        coordinator.options = options("caller")
        coordinator.updateMenu()
        precondition(control.menu === menu, "An open native menu was replaced")
        coordinator.menuDidClose(menu)
        coordinator.updateMenu()
        precondition(control.menu === menu, "The closing callback rebuilt its native menu")
        let deadline = Date().addingTimeInterval(2)
        while control.menu === menu && Date() < deadline {
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        precondition(control.menu!.items[2].state == .on && control.menu!.items[1].state == .off)
        control.menu!.performActionForItem(at: 3)
        precondition(selection == "agent", "Native menu selection did not invoke its action")
        coordinator.menuWillOpen(control.menu!)
        control.isEnabled = false
        control.menu!.performActionForItem(at: 2)
        precondition(selection == "agent", "A disabled control invoked an old menu action")
        coordinator.menuDidClose(control.menu!)
        coordinator.invalidate()
        print(
            "PASS combined split boundary, divider, unhighlighted dropdown, 44pt target, disabled state, menu lifecycle, and source selection."
        )
    }
}
