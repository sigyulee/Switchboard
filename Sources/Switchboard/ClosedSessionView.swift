import SwiftUI

struct ClosedSessionView: View {
    @Environment(\.appStrings) private var strings
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text(model.session.state?.name ?? "").font(.system(size: 26, weight: .semibold))
                if let description = model.session.state?.description, !description.isEmpty {
                    Text(description).font(.system(size: 16)).foregroundStyle(.secondary)
                }
            }.textSelection(.enabled).padding(24)
            Divider()
            if model.transcript.entries.isEmpty {
                Text(strings(.libraryNoTranscript)).font(.system(size: 16)).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TranscriptMessages(entries: model.transcript.entries)
            }
            Divider()
            HStack(spacing: 16) {
                Text(durationText(model.session.duration)).font(
                    .system(size: 20, weight: .light).monospacedDigit())
                Spacer()
                Button(strings(.actionDiscard), role: .destructive) { model.discardSession() }
                Button(strings(.actionSave)) { model.saveSession() }.buttonStyle(.borderedProminent)
            }.controlSize(.large).padding(24).disabled(model.session.busy || model.endingSession)
        }
    }
}
