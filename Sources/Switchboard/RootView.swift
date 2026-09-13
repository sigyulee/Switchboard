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
                ScrollView { SessionView(model: model).padding(24) }
            } else {
                LibraryView(model: model)
            }
            Divider()
            RecordingTransport(model: model)
        }
        .frame(minWidth: 680, minHeight: 620)
        .font(.system(size: 16))
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $model.showSetup) { SetupView(model: model).frame(width: 600).padding(28) }
        .sheet(isPresented: $model.showSettings) { SettingsView(model: model).frame(width: 540).padding(24) }
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
            }.pickerStyle(.segmented).labelsHidden().frame(width: 190)
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

struct SessionView: View {
    @Environment(\.appStrings) private var strings
    @Bindable var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                Label(strings(.sessionTitle), systemImage: "arrow.left.arrow.right").font(
                    .system(size: 17, weight: .semibold))
                Spacer()
                if model.requiresSetup {
                    Button(strings(.actionSetup)) { model.showSetup = true }.buttonStyle(.borderedProminent)
                } else {
                    Button(model.suspended ? strings(.actionResume) : strings(.actionPause)) {
                        if model.suspended { model.resume() } else { Task { await model.pause() } }
                    }.disabled(model.preview || model.installing || model.pausing)
                        .help(strings(.sessionPauseHelp))
                }
            }
            VStack(spacing: 0) {
                RouteRow(
                    icon: "phone.fill", title: strings(.routeCaller),
                    subtitle: model.phoneRunning ? "" : strings(.routePhoneWaiting),
                    available: model.audio.callerReady, level: model.audio.callerLevel,
                    error: model.audio.callerError.map { strings.error($0) })
                Divider().padding(.leading, 60)
                RouteRow(
                    icon: "macwindow", title: strings(.routeAgent),
                    subtitle: model.chromeRunning ? "" : strings(.routeChromeWaiting),
                    available: model.audio.chromeReady, level: model.audio.chromeLevel,
                    error: model.audio.chromeError.map { strings.error($0) })
            }
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.06)))
            ListeningView(model: model)
            DisclosureGroup(strings(.routeDeviceHelp)) {
                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent(strings(.routeAgentMicrophone), value: strings(.routeDefaultInput))
                    LabeledContent(strings(.routeCallerSpeaker), value: "Phone → Agent")
                    LabeledContent(strings(.routeCallerMicrophone), value: "Chrome → Phone")
                }.font(.system(size: 15)).padding(.top, 10)
            }.font(.system(size: 14)).foregroundStyle(.secondary)
        }
    }
}

struct RouteRow: View {
    @Environment(\.appStrings) private var strings
    let icon: String
    let title: String
    let subtitle: String
    let available: Bool
    let level: Float
    let error: String?
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 20)).foregroundStyle(available ? .blue : .secondary)
                .frame(width: 32, height: 36).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 16, weight: .medium))
                if !(error ?? subtitle).isEmpty {
                    Text(error ?? subtitle).font(.system(size: 14)).foregroundStyle(
                        error == nil ? Color.secondary : Color.orange
                    )
                    .lineLimit(2).help(error ?? subtitle)
                }
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 5) {
                LevelMeter(level: available ? level : 0).frame(width: 112, height: 14)
                if !available {
                    Text(strings(.routeWaiting)).font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }
        }.padding(16)
    }
}

struct LevelMeter: View {
    @Environment(\.appStrings) private var strings
    let level: Float
    private var normalized: Double { level > 0 ? max(0, min(1, (20 * log10(Double(level)) + 60) / 60)) : 0 }
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<22) { index in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(
                        Double(index) / 22 < normalized
                            ? (index > 19 ? Color.orange : Color.blue) : Color.primary.opacity(0.07))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(strings(.meterInput))
        .accessibilityValue(
            level > 0.001 ? strings(.meterDecibels, Int(20 * log10(Double(level)))) : strings(.meterSilence))
    }
}
