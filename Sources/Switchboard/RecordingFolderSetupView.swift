import SwiftUI

struct RecordingFolderSetupView: View {
    @Environment(\.appTypography) private var typography
    @Environment(\.appStrings) private var strings
    let folder: URL
    var busy = false
    var issue: OperationIssue?
    let choose: () -> Void
    let confirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 14) {
                SwitchboardMark().frame(width: 44, height: 44)
                Text("Switchboard").font(typography.title)
            }
            VStack(alignment: .leading, spacing: 10) {
                Text(strings(.settingsDefaultFolder)).font(typography.panelTitle)
                Text(strings(.folderChooseDescription)).font(typography.body).foregroundStyle(.secondary)
                Label(folder.path, systemImage: "folder")
                    .font(typography.body).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            }
            if let issue {
                InlineIssueView(message: strings(issue.message), details: issue.details)
            }
            HStack {
                Button(strings(.settingsChangeFolder), action: choose)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button(strings(.folderUse), action: confirm)
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }.controlSize(.large).disabled(busy)
        }
        .padding(32).frame(maxWidth: 600)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minWidth: 680, minHeight: 620)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
