import AppKit
import Foundation

@main @MainActor struct Checks {
    static func main() async throws {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 240, height: 100))
        let text = TranscriptSearchTextView(frame: NSRect(x: 0, y: 0, width: 220, height: 3000))
        text.isEditable = false
        text.textContainerInset = .zero
        text.textContainer?.lineFragmentPadding = 0
        text.textContainer?.widthTracksTextView = false
        text.textContainer?.containerSize = NSSize(width: 220, height: CGFloat.greatestFiniteMagnitude)
        text.string = (0..<100).map { "Row \($0): transcript match\n" }.joined()
        text.font = .systemFont(ofSize: 16)
        scroll.documentView = text
        defer { text.cancelReveal() }
        let whole = text.string as NSString
        let last = whole.range(of: "Row 90")
        text.reveal(last, request: UUID())
        await settle()
        try require(visible(last, in: text), "long-message match is outside the visible region")
        try require(scroll.contentView.bounds.minY > 100, "find did not scroll to the actual occurrence")
        let first = whole.range(of: "Row 0:")
        let firstRequest = UUID()
        text.reveal(first, request: firstRequest)
        await settle()
        try require(visible(first, in: text), "previous result did not return to the first occurrence")
        print("PASS exact first/last match visibility in long native text")

        scroll.contentView.scroll(to: NSPoint(x: 0, y: 220))
        let userPosition = scroll.contentView.bounds.origin
        text.reveal(first, request: firstRequest)
        await settle()
        try require(
            scroll.contentView.bounds.origin == userPosition, "unchanged results overrode manual scrolling")
        text.reveal(last, request: UUID())
        text.cancelReveal()
        await settle()
        try require(scroll.contentView.bounds.origin == userPosition, "cancelled reveal still scrolled")
        print("PASS manual scroll and cancelled find navigation are preserved")

        text.reveal(last, request: UUID())
        text.reveal(first, request: UUID())
        await settle()
        try require(visible(first, in: text), "stale reveal displaced the newest result")
        let beforeInvalid = scroll.contentView.bounds.origin
        text.reveal(NSRange(location: NSNotFound, length: 0), request: UUID())
        await settle()
        try require(scroll.contentView.bounds.origin == beforeInvalid, "invalid text range changed position")
        print("PASS newest request wins and invalid ranges are ignored")
    }
    private static func visible(_ range: NSRange, in view: NSTextView) -> Bool {
        guard let layout = view.layoutManager, let container = view.textContainer else { return false }
        layout.ensureLayout(for: container)
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
        return view.visibleRect.insetBy(dx: -1, dy: -1).contains(rect)
    }
    private static func settle() async { for _ in 0..<10 { await Task.yield() } }
    private static func require(_ value: Bool, _ message: String) throws {
        if !value {
            throw NSError(
                domain: "TranscriptSearchLayout", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }
}
