import SwiftUI

struct InlineIssueView: View {
    @Environment(\.appTypography) private var typography
    @Environment(\.appStrings) private var strings
    let message: String
    var details: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(message, systemImage: "exclamationmark.circle.fill")
                .font(typography.body).foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
            if let details, !details.isEmpty, details != message {
                DisclosureGroup(strings(.errorDetails)) {
                    ScrollView {
                        Text(details).font(typography.caption).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }.frame(maxHeight: 140).fixedSize(horizontal: false, vertical: true)
                }.disclosureGroupStyle(FullRowDisclosureStyle())
            }
        }.padding(12)
            .background(.red.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityElement(children: .contain)
    }
}

struct FullRowDisclosureStyle: DisclosureGroupStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) {
                    configuration.isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right").font(.caption)
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                        .foregroundStyle(.secondary).accessibilityHidden(true)
                    configuration.label
                    Spacer(minLength: 0)
                }.padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.disabled).contentShape(Rectangle()).hoverBackground()
            }.buttonStyle(.plain)
            if configuration.isExpanded {
                configuration.content.padding(.top, 8).padding(.leading, 18)
            }
        }
    }
}
