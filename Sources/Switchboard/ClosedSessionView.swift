import SwiftUI

struct ClosedSessionView: View {
    @Environment(\.appTypography) private var typography
    @Environment(\.appStrings) private var strings
    @Environment(AppFindController.self) private var findController
    @Bindable var model: AppModel
    @ViewState private var fallbackTranscriptID = UUID()
    private var transcriptID: UUID { model.session.sessionID ?? fallbackTranscriptID }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                SessionHeading(
                    name: model.session.sessionName,
                    description: model.session.sessionDescription,
                    duration: model.session.duration)
                Spacer()
                if !model.transcript.entries.isEmpty {
                    IconButton("magnifyingglass", label: strings(.transcriptSearch)) {
                        findController.findTranscript(owner: transcriptID)
                    }
                }
            }.padding(24)
            Divider()
            if model.transcript.entries.isEmpty {
                Text(strings(.libraryNoTranscript)).font(typography.body).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TranscriptMessages(transcriptID: transcriptID, entries: model.transcript.entries)
                    .id(transcriptID)
            }
            Divider()
            HStack(spacing: 16) {
                Button(strings(.actionBack)) { model.closeSessionView() }
                Spacer()
                Button(strings(.actionDiscard), role: .destructive) { model.discardSession() }
                Button(strings(.actionSave)) { model.saveSession() }.buttonStyle(.borderedProminent)
            }.controlSize(.large).padding(24).disabled(model.session.busy || model.endingSession)
        }
    }
}
