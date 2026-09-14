import SwiftUI

struct SplitActionButton<Options: View>: View {
    @Environment(\.appTypography) private var typography
    let title: String
    let systemImage: String
    let menuLabel: String
    let action: () -> Void
    @ViewBuilder var options: Options
    private var height: CGFloat { max(44, typography.controlSide) }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: action) {
                Label(title, systemImage: systemImage)
                    .font(typography.body.weight(.medium))
                    .padding(.leading, 16).padding(.trailing, 14)
                    .frame(minHeight: height)
                    .contentShape(Rectangle())
            }.buttonStyle(SplitSegmentStyle())
            Rectangle().fill(Color(nsColor: .separatorColor))
                .frame(width: 1, height: height - 20).accessibilityHidden(true)
            Menu {
                options
            } label: {
                Label(menuLabel, systemImage: "chevron.down").labelStyle(.iconOnly)
                    .font(typography.body.weight(.medium))
                    .frame(width: height, height: height)
                    .contentShape(Rectangle())
            }.menuStyle(.button).buttonStyle(SplitSegmentStyle()).menuIndicator(.hidden)
                .accessibilityLabel(menuLabel).help(menuLabel)
        }
        .buttonBorderShape(.roundedRectangle(radius: 0))
        .background(.quaternary, in: Capsule())
        .clipShape(Capsule())
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .contain)
    }
}

private struct SplitSegmentStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @ViewState private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(enabled ? .primary : .secondary)
            .background(
                Color.primary.opacity(enabled ? configuration.isPressed ? 0.14 : hovering ? 0.06 : 0 : 0)
            )
            .onHover { hovering = $0 }
    }
}
