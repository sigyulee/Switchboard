import AppKit
import SwiftUI

/// Keeps the library divider independent of the selected recording's intrinsic content size.
struct LibrarySplitView<Sidebar: View, Detail: View>: NSViewRepresentable {
    @Binding private var sidebarWidth: Double
    private let sidebar: Sidebar
    private let detail: Detail

    init(
        sidebarWidth: Binding<Double>, @ViewBuilder sidebar: () -> Sidebar,
        @ViewBuilder detail: () -> Detail
    ) {
        _sidebarWidth = sidebarWidth
        self.sidebar = sidebar()
        self.detail = detail()
    }

    func makeCoordinator() -> LibrarySplitCoordinator {
        LibrarySplitCoordinator(sidebarWidth: $sidebarWidth)
    }

    func makeNSView(context: Context) -> LibrarySplitContainer {
        let split = LibrarySplitContainer()
        context.coordinator.attach(split)
        updateNSView(split, context: context)
        return split
    }

    func updateNSView(_ nsView: LibrarySplitContainer, context: Context) {
        context.coordinator.update(
            sidebarWidth: $sidebarWidth, sidebar: AnyView(sidebar), detail: AnyView(detail),
            environment: context.environment)
    }

    static func dismantleNSView(_ nsView: LibrarySplitContainer, coordinator: LibrarySplitCoordinator) {
        coordinator.detach(nsView)
    }
}

@MainActor final class LibrarySplitContainer: NSSplitView {
    let sidebarHost = LibrarySidebarHostingView(rootView: AnyView(EmptyView()))
    let detailHost = NSHostingView(rootView: AnyView(EmptyView()))

    init() {
        super.init(frame: .zero)
        isVertical = true
        dividerStyle = .thin
        for host in [sidebarHost, detailHost] {
            // Pane geometry belongs to NSSplitView, not a newly selected transcript's ideal size.
            host.sizingOptions = []
            addArrangedSubview(host)
        }
        setHoldingPriority(NSLayoutConstraint.Priority(rawValue: 480), forSubviewAt: 0)
        setHoldingPriority(.defaultLow, forSubviewAt: 1)
    }

    required init?(coder: NSCoder) { nil }
}

@MainActor final class LibrarySidebarHostingView: NSHostingView<AnyView> {
    override func layout() {
        super.layout()
        suppressListFocusRing(in: self)
    }

    private func suppressListFocusRing(in view: NSView) {
        if let table = view as? NSTableView {
            // SwiftUI's focus effect modifier leaves the native table's ring enabled.
            // The selected row still indicates focus and native keyboard navigation is retained.
            table.focusRingType = .none
            table.enclosingScrollView?.focusRingType = .none
            return
        }
        for child in view.subviews { suppressListFocusRing(in: child) }
    }
}

@MainActor final class LibrarySplitCoordinator: NSObject, NSSplitViewDelegate {
    private weak var split: LibrarySplitContainer?
    private var sidebarWidth: Binding<Double>
    private var preferredWidth: Double
    private var receivedWidth: Double
    private var appliedWidth: CGFloat = 0
    private var applyingLayout = false
    private var publication: Task<Void, Never>?

    init(sidebarWidth: Binding<Double>) {
        self.sidebarWidth = sidebarWidth
        let width = Self.normalized(sidebarWidth.wrappedValue)
        preferredWidth = width
        receivedWidth = width
    }

    func attach(_ split: LibrarySplitContainer) {
        self.split = split
        split.delegate = self
        layoutPanes()
    }

    func detach(_ split: LibrarySplitContainer) {
        guard self.split === split else { return }
        publication?.cancel()
        publication = nil
        split.delegate = nil
        self.split = nil
    }

    func update(
        sidebarWidth: Binding<Double>, sidebar: AnyView, detail: AnyView, environment: EnvironmentValues
    ) {
        guard let split else { return }
        self.sidebarWidth = sidebarWidth
        let width = Self.normalized(sidebarWidth.wrappedValue)
        if width != receivedWidth {
            publication?.cancel()
            publication = nil
            receivedWidth = width
            preferredWidth = width
        }
        applyingLayout = true
        // Forward the full context, including appStrings, appTypography, locale, and system appearance.
        split.sidebarHost.rootView = AnyView(sidebar.environment(\.self, environment))
        split.detailHost.rootView = AnyView(detail.environment(\.self, environment))
        applyingLayout = false
        layoutPanes()
    }

    func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
        layoutPanes()
    }

    func splitView(_ splitView: NSSplitView, shouldAdjustSizeOfSubview view: NSView) -> Bool {
        view !== split?.sidebarHost
    }

    func splitView(
        _ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        max(proposedMinimumPosition, min(280, maximumSidebarWidth(in: splitView)))
    }

    func splitView(
        _ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        min(proposedMaximumPosition, maximumSidebarWidth(in: splitView))
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard !applyingLayout, let split,
            let changed = notification.object as? NSSplitView, changed === split
        else { return }
        let width = split.sidebarHost.frame.width
        // Window resizing and content updates already recorded their applied width. Only a divider
        // move introduces a different width here; a temporary window clamp must not become a preference.
        guard width.isFinite, abs(width - appliedWidth) > 0.5 else { return }
        appliedWidth = width
        preferredWidth = Self.normalized(Double(width))
        publish(preferredWidth)
    }

    private func layoutPanes() {
        guard let split else { return }
        applyingLayout = true
        defer { applyingLayout = false }
        let width = min(CGFloat(preferredWidth), maximumSidebarWidth(in: split))
        let available = max(0, split.bounds.width - split.dividerThickness)
        let height = max(0, split.bounds.height)
        appliedWidth = width
        split.sidebarHost.frame = NSRect(x: 0, y: 0, width: width, height: height)
        split.detailHost.frame = NSRect(
            x: width + split.dividerThickness, y: 0, width: max(0, available - width), height: height)
    }

    private func maximumSidebarWidth(in split: NSSplitView) -> CGFloat {
        min(420, max(0, split.bounds.width - split.dividerThickness - 360))
    }

    private static func normalized(_ width: Double) -> Double {
        width.isFinite ? min(420, max(280, width)) : 320
    }

    private func publish(_ width: Double) {
        publication?.cancel()
        publication = Task { @MainActor [weak self] in
            guard !Task.isCancelled, let self, split != nil else { return }
            receivedWidth = width
            sidebarWidth.wrappedValue = width
            publication = nil
        }
    }

    deinit { publication?.cancel() }
}
