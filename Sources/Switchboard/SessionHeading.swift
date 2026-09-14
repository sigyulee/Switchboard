import SwiftUI

struct SessionHeading: View {
    @Environment(\.appTypography) private var typography
    @Environment(\.appStrings) private var strings
    let name: String
    let description: String
    let duration: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    title.fixedSize()
                    Spacer(minLength: 0)
                    elapsed
                }
                VStack(alignment: .leading, spacing: 8) {
                    title
                    elapsed
                }
            }
            if !description.isEmpty {
                Text(description).font(typography.body).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
    }

    private var title: some View {
        Text(name).font(typography.title)
    }

    private var elapsed: some View {
        Text(durationText(duration))
            .font(typography.body.monospacedDigit()).foregroundStyle(.secondary)
            .fixedSize().accessibilityLabel(strings(.sessionDuration))
            .accessibilityValue(durationText(duration))
    }
}
