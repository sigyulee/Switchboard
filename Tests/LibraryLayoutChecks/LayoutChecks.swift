import AppKit
import Darwin
import Foundation
import SwiftUI

private struct LayoutCheckFailure: Error, CustomStringConvertible {
    let description: String
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw LayoutCheckFailure(description: message) }
}

@MainActor private final class WidthSelection {
    var width: Double
    var writes: [Double] = []
    let events: AsyncStream<Double>
    private let continuation: AsyncStream<Double>.Continuation

    init(_ width: Double) {
        self.width = width
        (events, continuation) = AsyncStream.makeStream()
    }

    var binding: Binding<Double> {
        Binding(
            get: { self.width },
            set: {
                self.width = $0
                self.writes.append($0)
                self.continuation.yield($0)
            })
    }
}

@MainActor private final class CoordinatorReference {
    weak var value: LibrarySplitCoordinator?
}

private struct FocusListProbe: View {
    @ViewState private var selection: Int?
    @FocusState private var focused: Bool

    var body: some View {
        List(selection: $selection) {
            Text("First recording").tag(1)
            Text("Second recording").tag(2)
        }.listStyle(.plain).focusable().focused($focused).focusEffectDisabled()
    }
}

@main @MainActor struct LibraryLayoutChecks {
    static func main() async {
        let checks: [(String, @MainActor () async throws -> Void)] = [
            ("divider selection survives different detail content", contentReplacementPreservesDraggedWidth),
            (
                "narrow windows preserve the preferred width for later restoration",
                windowResizePreservesPreference
            ),
            ("native divider constraints bound the sidebar", dividerConstraintsAndInvalidPreferences),
            ("both hosting views receive updated environments", hostingBoundariesPreserveEnvironment),
            ("native list focus rings stay disabled across content replacement", listFocusRing),
            ("dismantling releases the delegate and cancels pending writes", dismantlingCancelsPublication),
        ]
        var failures = 0
        for (name, check) in checks {
            do {
                try await check()
                print("PASS \(name)")
            } catch {
                failures += 1
                print("FAIL \(name): \(error)")
            }
        }
        if failures > 0 { exit(1) }
        print("\(checks.count) library layout checks passed without displaying windows.")
    }

    private static func contentReplacementPreservesDraggedWidth() async throws {
        let selection = WidthSelection(320)
        let coordinator = LibrarySplitCoordinator(sidebarWidth: selection.binding)
        let split = LibrarySplitContainer()
        coordinator.attach(split)
        defer { coordinator.detach(split) }
        split.setFrameSize(NSSize(width: 1000, height: 500))
        update(coordinator, selection: selection, detail: AnyView(Text("First recording")))
        let sidebar = split.sidebarHost
        let detail = split.detailHost

        // NSSplitView applies the same delegate constraints as native divider dragging.
        split.setPosition(388, ofDividerAt: 0)
        try require(abs(sidebar.frame.width - 388) < 1, "The native divider did not move")
        try require(selection.writes.isEmpty, "Divider changes were published synchronously during layout")
        update(
            coordinator, selection: selection,
            detail: AnyView(Text(String(repeating: "Long transcript ", count: 500)).frame(minWidth: 1400)))
        split.layoutSubtreeIfNeeded()
        try require(
            split.sidebarHost === sidebar && split.detailHost === detail,
            "Content replacement recreated hosts")
        try require(abs(sidebar.frame.width - 388) < 1, "The new transcript reset the dragged sidebar width")
        let published = try await nextValue(from: selection.events)
        try require(abs(published - 388) < 1, "The dragged width was not stored")
        update(coordinator, selection: selection, detail: AnyView(Color.clear))
        try require(abs(sidebar.frame.width - 388) < 1, "A second selection reset the stored sidebar width")
    }

    private static func windowResizePreservesPreference() async throws {
        let selection = WidthSelection(396)
        let coordinator = LibrarySplitCoordinator(sidebarWidth: selection.binding)
        let split = LibrarySplitContainer()
        coordinator.attach(split)
        defer { coordinator.detach(split) }
        split.setFrameSize(NSSize(width: 1000, height: 500))
        update(coordinator, selection: selection)
        try require(
            abs(split.sidebarHost.frame.width - 396) < 1, "The saved width was not restored initially")
        split.setFrameSize(NSSize(width: 620, height: 400))
        try require(split.sidebarHost.frame.width < 280, "A narrow window did not clamp the sidebar")
        try require(split.detailHost.frame.width >= 360, "The narrow layout consumed the transcript minimum")
        try require(
            selection.width == 396 && selection.writes.isEmpty, "Window clamping overwrote the preference")
        split.setFrameSize(NSSize(width: 1100, height: 600))
        try require(
            abs(split.sidebarHost.frame.width - 396) < 1, "Widening the window lost the preferred width")
        split.setFrameSize(NSSize(width: 100, height: 300))
        try require(
            split.sidebarHost.frame.width >= 0 && split.detailHost.frame.width >= 0,
            "A tiny view produced negative widths")
        try require(
            abs(split.detailHost.frame.maxX - split.bounds.maxX) < 1,
            "A tiny view placed a pane outside its bounds")
        try require(selection.writes.isEmpty, "Window resizing was mistaken for divider dragging")
    }

    private static func dividerConstraintsAndInvalidPreferences() async throws {
        for (input, expected) in [(Double.nan, 320.0), (.infinity, 320), (-1, 280), (900, 420)] {
            let selection = WidthSelection(input)
            let coordinator = LibrarySplitCoordinator(sidebarWidth: selection.binding)
            let split = LibrarySplitContainer()
            coordinator.attach(split)
            split.setFrameSize(NSSize(width: 1000, height: 500))
            update(coordinator, selection: selection)
            try require(
                abs(split.sidebarHost.frame.width - expected) < 1,
                "An invalid preference broke initial layout")
            split.setPosition(100, ofDividerAt: 0)
            try require(abs(split.sidebarHost.frame.width - 280) < 1, "Dragging ignored the sidebar minimum")
            split.setPosition(900, ofDividerAt: 0)
            try require(abs(split.sidebarHost.frame.width - 420) < 1, "Dragging ignored the sidebar maximum")
            try require(split.detailHost.frame.width >= 360, "Dragging consumed the transcript minimum")
            coordinator.detach(split)
        }
    }

    private static func hostingBoundariesPreserveEnvironment() async throws {
        let selection = WidthSelection(320)
        let coordinator = LibrarySplitCoordinator(sidebarWidth: selection.binding)
        let split = LibrarySplitContainer()
        coordinator.attach(split)
        defer { coordinator.detach(split) }
        split.setFrameSize(NSSize(width: 1000, height: 500))
        var environment = EnvironmentValues()
        environment.appStrings = LayoutStrings(language: "ko")
        environment.appTypography = LayoutTypography(scale: 1.4)
        environment.locale = Locale(identifier: "ko_KR")
        coordinator.update(
            sidebarWidth: selection.binding, sidebar: AnyView(EnvironmentProbe()),
            detail: AnyView(EnvironmentProbe()), environment: environment)
        for host in [split.sidebarHost, split.detailHost] {
            host.layoutSubtreeIfNeeded()
            guard let probe = descendant(EnvironmentProbeView.self, in: host) else {
                throw LayoutCheckFailure(description: "The SwiftUI environment probe was not hosted")
            }
            try require(
                probe.language == "ko" && probe.scale == 1.4 && probe.locale == "ko_KR",
                "A hosting boundary lost its environment")
        }
        environment.appStrings = LayoutStrings(language: "en")
        environment.appTypography = LayoutTypography(scale: 1)
        environment.locale = Locale(identifier: "en_US")
        coordinator.update(
            sidebarWidth: selection.binding, sidebar: AnyView(EnvironmentProbe()),
            detail: AnyView(EnvironmentProbe()), environment: environment)
        for host in [split.sidebarHost, split.detailHost] {
            host.layoutSubtreeIfNeeded()
            guard let probe = descendant(EnvironmentProbeView.self, in: host) else {
                throw LayoutCheckFailure(description: "The updated environment probe was not hosted")
            }
            try require(
                probe.language == "en" && probe.scale == 1 && probe.locale == "en_US",
                "A hosting boundary kept a stale environment")
        }
    }

    private static func dismantlingCancelsPublication() async throws {
        let selection = WidthSelection(320)
        let split = LibrarySplitContainer()
        let reference = CoordinatorReference()
        autoreleasepool {
            let coordinator = LibrarySplitCoordinator(sidebarWidth: selection.binding)
            reference.value = coordinator
            coordinator.attach(split)
            split.setFrameSize(NSSize(width: 1000, height: 500))
            update(coordinator, selection: selection)
            split.setPosition(380, ofDividerAt: 0)
            coordinator.detach(split)
        }
        try require(
            reference.value == nil && split.delegate == nil, "The split view retained its coordinator")
        await Task.yield()
        try require(selection.writes.isEmpty, "A removed split view published an old divider change")
    }

    private static func listFocusRing() async throws {
        let selection = WidthSelection(320)
        let coordinator = LibrarySplitCoordinator(sidebarWidth: selection.binding)
        let split = LibrarySplitContainer()
        coordinator.attach(split)
        defer { coordinator.detach(split) }
        split.setFrameSize(NSSize(width: 1000, height: 500))
        for revision in 0..<2 {
            if revision > 0 {
                update(coordinator, selection: selection)
                split.sidebarHost.layoutSubtreeIfNeeded()
            }
            coordinator.update(
                sidebarWidth: selection.binding, sidebar: AnyView(FocusListProbe()),
                detail: AnyView(Text("Transcript")), environment: EnvironmentValues())
            split.sidebarHost.layoutSubtreeIfNeeded()
            guard let table = descendant(NSTableView.self, in: split.sidebarHost) else {
                throw LayoutCheckFailure(description: "The native SwiftUI list was not hosted")
            }
            try require(table.focusRingType == .none, "The native list still draws an exterior focus ring")
            try require(
                table.enclosingScrollView?.focusRingType == NSFocusRingType.none,
                "The list scroll view draws a focus ring")
            try require(table.acceptsFirstResponder, "Removing the ring disabled keyboard focus")
            table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
            try require(table.selectedRow == 1, "The native selection no longer works")
        }
    }

    private static func update(
        _ coordinator: LibrarySplitCoordinator, selection: WidthSelection,
        detail: AnyView = AnyView(Text("Recording"))
    ) {
        coordinator.update(
            sidebarWidth: selection.binding, sidebar: AnyView(Text("Library")), detail: detail,
            environment: EnvironmentValues())
    }

    private static func descendant<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        return view.subviews.lazy.compactMap { descendant(type, in: $0) }.first
    }

    private static func nextValue(from stream: AsyncStream<Double>) async throws -> Double {
        try await withThrowingTaskGroup(of: Double.self) { group in
            group.addTask {
                for await value in stream { return value }
                throw LayoutCheckFailure(description: "Divider publication ended without a value")
            }
            group.addTask {
                try await Task.sleep(for: .seconds(2))
                throw LayoutCheckFailure(description: "Divider publication timed out")
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
}
