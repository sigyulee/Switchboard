import SwiftUI

struct RootView: View {
    private var typography: AppTypography { AppTypography(textSize: model.textSize) }
    @Environment(\.appStrings) private var strings
    @Environment(\.openWindow) private var openWindow
    @Bindable var model: AppModel
    @ViewState private var findController = AppFindController()
    var body: some View {
        Group {
            if model.language == nil {
                LanguageChoiceView(choose: model.chooseLanguage)
            } else if model.needsRecordingFolderSetup {
                RecordingFolderSetupView(
                    folder: model.recordingRoot, busy: model.recordingFolderBusy,
                    issue: model.recordingFolderIssue, choose: model.chooseRecordingFolder,
                    confirm: { model.useRecordingFolder(model.recordingRoot) })
            } else {
                content
            }
        }
        .onAppear { model.openMainWindow = { openWindow(id: "main") } }
        .environment(\.appTypography, typography)
        .environment(findController)
        .focusedSceneValue(\.appFindController, findController)
        .onChange(of: model.page) { findController.focusLibrary() }
    }
    private var content: some View {
        VStack(spacing: 0) {
            header
            if model.preview {
                Label(strings(.previewNotice), systemImage: "eye")
                    .font(typography.caption).foregroundStyle(.secondary).padding(.bottom, 12)
            }
            Divider()
            if model.page == "library" {
                LibraryView(model: model)
            } else if model.openingDraft {
                ProgressView(strings(.sessionOpening))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.session.closed {
                ClosedSessionView(model: model)
            } else if model.page == "session" {
                if model.session.hasSession {
                    ActiveSessionView(model: model)
                } else {
                    ScrollView { SessionHomeView(model: model).padding(32) }
                }
            } else {
                LibraryView(model: model)
            }
        }
        .frame(minWidth: 860, minHeight: 620)
        .font(typography.body)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $model.showSetup) {
            SettingsSurface(width: 600, maximumHeight: 620) { SetupView(model: model) }
        }
        .sheet(isPresented: $model.showSettings) {
            SettingsSurface(width: 620) { SettingsView(model: model) }
        }
        .confirmationDialog(
            strings(.sessionEndTitle), isPresented: $model.showEndSession, titleVisibility: .visible
        ) {
            Button(strings(.actionSave)) { model.saveSession() }
            Button(strings(.actionDiscard), role: .destructive) { model.discardSession() }
            Button(strings(.actionCancel), role: .cancel) { model.session.cancelEnd() }
        }
        .alert(
            strings(.alertTitle),
            isPresented: Binding(
                get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
        ) {
            Button(strings(.actionOk), role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
    private var header: some View {
        HStack(spacing: 12) {
            SwitchboardMark().frame(width: 44, height: 44)
            Text("Switchboard").font(typography.title)
            Spacer(minLength: 20)
            Picker(
                strings(.navigationView),
                selection: Binding(get: { model.page }, set: { model.navigate(to: $0) })
            ) {
                Text(strings(.navigationSession)).tag("session")
                Text(strings(.navigationRecordings)).tag("library")
            }.pickerStyle(.segmented).controlSize(.large).font(typography.body)
                .labelsHidden().fixedSize()
                .disabled(model.openingDraft || model.endingSession)
            IconButton("gearshape", label: strings(.navigationSettings)) {
                model.showSettings = true
            }
        }.padding(.horizontal, 24).padding(.vertical, 18)
    }
}
