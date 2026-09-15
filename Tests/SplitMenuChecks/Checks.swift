import AppKit
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
    static func main() {
        _ = NSApplication.shared
        let control = SplitMenuControl(frame: NSRect(x: 0, y: 0, width: 44, height: 44), pullsDown: true)
        control.cell = SplitMenuCell(textCell: "", pullsDown: true)
        control.isBordered = false
        precondition(control.intrinsicContentSize == NSSize(width: 44, height: 44))
        control.menuIsOpen = true
        let pressed = rendered(control)
        precondition(
            pressed.colorAt(x: 1, y: 1)!.alphaComponent > 0.1,
            "Inner edge must stay flat when the menu is open")
        precondition(
            pressed.colorAt(x: pressed.pixelsWide - 2, y: 1)!.alphaComponent < 0.02,
            "Outer corner must stay rounded")
        precondition(
            pressed.colorAt(x: 4, y: pressed.pixelsHigh / 2)!.alphaComponent > 0.1,
            "The inner segment must be filled continuously")
        control.menuIsOpen = false
        control.hovering = true
        let hover = rendered(control)
        precondition(hover.colorAt(x: 1, y: 1)!.alphaComponent > 0.02, "Hover must cover the flat inner edge")
        precondition(hover.colorAt(x: 1, y: 1)!.alphaComponent < pressed.colorAt(x: 1, y: 1)!.alphaComponent)
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
            "PASS flat inner highlight, rounded outer edge, 44pt target, disabled state, menu lifecycle, and source selection."
        )
    }
}
