import SwiftUI

struct RootView: View {
    @Environment(\.appStrings) private var strings
    @Environment(\.openWindow) private var openWindow
    @Bindable var model: AppModel
    var body: some View {
        Group {
            if model.language == nil {
                LanguageChoiceView(choose: model.chooseLanguage)
            } else {
                content
            }
        }
        .onAppear { model.openMainWindow = { openWindow(id: "main") } }
    }
    private var content: some View {
        VStack(spacing: 0) {
            header
            if model.preview {
                Label(strings(.previewNotice), systemImage: "eye")
                    .font(.system(size: 14)).foregroundStyle(.secondary).padding(.bottom, 12)
            }
            Divider()
            if model.page == "session" {
                if model.session.closed {
                    ClosedSessionView(model: model)
                } else if model.session.state != nil {
                    ActiveSessionView(model: model)
                } else {
                    ScrollView { SessionHomeView(model: model).padding(32) }
                }
            } else {
                LibraryView(model: model)
            }
        }
        .frame(minWidth: 860, minHeight: 620)
        .font(.system(size: 16))
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $model.showSetup) { SetupView(model: model).frame(width: 600).padding(28) }
        .sheet(isPresented: $model.showSettings) { SettingsView(model: model).frame(width: 540).padding(24) }
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
            Text("Switchboard").font(.system(size: 24, weight: .semibold))
            Spacer(minLength: 20)
            Picker(strings(.navigationView), selection: $model.page) {
                Text(strings(.navigationSession)).tag("session")
                Text(strings(.navigationRecordings)).tag("library")
            }.pickerStyle(.segmented).labelsHidden().fixedSize()
            Button {
                model.showSettings = true
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain).font(.system(size: 17)).padding(6).help(strings(.navigationSettings))
            .accessibilityLabel(strings(.navigationSettings))
        }.padding(.horizontal, 24).padding(.vertical, 18)
    }
}
