import SwiftUI

struct ControlIcon: View {
    @Environment(\.appTypography) private var typography
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .font(typography.panelTitle.weight(.medium))
            .frame(width: typography.controlSide, height: typography.controlSide)
            .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct IconButton: View {
    let systemName: String
    let label: String
    let action: () -> Void

    init(_ systemName: String, label: String, action: @escaping () -> Void) {
        self.systemName = systemName
        self.label = label
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            ControlIcon(systemName: systemName).hoverBackground()
        }
        .buttonStyle(.plain).accessibilityLabel(label).help(label)
    }
}

private struct HoverBackground: ViewModifier {
    @Environment(\.isEnabled) private var enabled
    @ViewState private var hovering = false
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(
                Color.primary.opacity(hovering && enabled ? 0.06 : 0),
                in: RoundedRectangle(cornerRadius: cornerRadius)
            )
            .onHover { hovering = $0 }
    }
}

extension View {
    func hoverBackground(cornerRadius: CGFloat = 8) -> some View {
        modifier(HoverBackground(cornerRadius: cornerRadius))
    }
}
