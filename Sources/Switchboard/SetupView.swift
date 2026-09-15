import BridgeCore
import SwiftUI

struct SetupView: View {
    @Environment(\.appTypography) private var typography
    @Environment(\.appStrings) private var strings
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    private var microphoneStatus: String? {
        switch model.microphoneAccess.status {
        case .authorized: strings(.setupAllowed)
        case .denied: strings(.setupNotAllowed)
        case .restricted: strings(.setupRestricted)
        default: nil
        }
    }
    private var audioAccessStatus: String? {
        if model.captureRequestInProgress { return strings(.setupRequesting) }
        if model.captureAccessIssue != nil { return strings(.setupAccessFailed) }
        return model.captureAccessRequested ? strings(.setupRequested) : nil
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(strings(.setupTitle)).font(typography.title)
                Spacer()
                IconButton("xmark", label: strings(.actionClose)) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            if model.driversReady {
                HStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        .frame(width: 28).accessibilityHidden(true)
                    Text(strings(.setupDevicesInstalled)).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }.font(typography.body).padding(.vertical, 4)
            } else {
                SetupRow(
                    systemImage: "waveform.path", title: strings(.setupDevices),
                    detail: strings(.setupDevicesHelp)
                ) {
                    Button(strings(model.installing ? .setupInstalling : .setupInstall)) {
                        Task { await model.installDrivers() }
                    }.disabled(model.installing || model.preview)
                }
            }
            if let issue = model.driverIssue {
                InlineIssueView(message: strings(issue.message), details: issue.details)
            }
            if !model.driversReady {
                Text(strings(.setupInstallHelp))
                    .font(typography.caption).foregroundStyle(.secondary).fixedSize(
                        horizontal: false, vertical: true)
            }
            Divider()
            VStack(spacing: 0) {
                SetupRow(
                    systemImage: "mic", title: strings(.setupMicrophone),
                    detail: strings(.setupMicrophoneHelp),
                    ready: model.microphoneAllowed,
                    status: microphoneStatus,
                    isError: model.microphoneAccess.status == .denied
                        || model.microphoneAccess.status == .restricted
                ) {
                    if model.microphoneAccess.status == .notDetermined {
                        Button(strings(.setupRequestMicrophone)) { model.requestMicrophone() }
                            .disabled(model.microphoneAccess.isRequesting || model.preview)
                    } else {
                        Button(strings(.setupManageAccess)) { model.openMicrophonePrivacy() }
                            .disabled(model.preview)
                    }
                }
                Divider().padding(.leading, 44)
                SetupRow(
                    systemImage: "speaker.wave.2", title: strings(.setupChrome),
                    detail: strings(.setupChromeHelp), status: audioAccessStatus,
                    isError: model.captureAccessIssue != nil
                ) {
                    if model.captureAccessRequested {
                        Button(strings(.setupManageAccess)) { model.openAudioPrivacy() }.disabled(
                            model.preview)
                    } else {
                        Button(strings(.setupRequestAudio)) { model.requestAgentAccess() }
                            .disabled(model.preview || model.captureRequestInProgress)
                    }
                }
            }
            if let issue = model.captureAccessIssue {
                InlineIssueView(message: strings(issue.message), details: issue.details)
            }
        }
    }
}

struct SetupRow<Control: View>: View {
    @Environment(\.appTypography) private var typography
    @Environment(\.appStrings) private var strings
    let systemImage: String
    let title: String
    let detail: String
    var ready = false
    var status: String? = nil
    var isError = false
    @ViewBuilder var control: Control
    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            ZStack {
                Circle().fill(
                    isError
                        ? Color.red.opacity(0.12)
                        : ready ? Color.green.opacity(0.12) : Color.primary.opacity(0.06))
                if isError {
                    Image(systemName: "exclamationmark").foregroundStyle(.red)
                } else if ready {
                    Image(systemName: "checkmark").foregroundStyle(.green)
                } else {
                    Image(systemName: systemImage).foregroundStyle(.secondary)
                }
            }.font(typography.caption.weight(.semibold)).frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(title).font(typography.row).fixedSize(horizontal: false, vertical: true)
                    if let status {
                        Text(status).font(typography.caption).foregroundStyle(
                            isError ? Color.red : .secondary
                        ).fixedSize()
                    }
                }
                Text(detail).font(typography.caption).lineSpacing(2).foregroundStyle(.secondary).fixedSize(
                    horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            control.controlSize(.large).font(typography.body).fixedSize()
        }.padding(.vertical, 16)
    }
}

struct SettingsView: View {
    @Environment(\.appTypography) private var typography
    @Environment(\.appStrings) private var strings
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @ViewState private var showSetup = false
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text(strings(.navigationSettings)).font(typography.panelTitle)
                Spacer()
                Button(strings(.actionDone)) { dismiss() }
            }
            Picker(
                strings(.settingsLanguage),
                selection: Binding(
                    get: { model.language ?? .english }, set: { model.chooseLanguage($0) }
                )
            ) {
                ForEach(ApplicationLanguage.allCases) { language in
                    Text(language.nativeName).tag(language)
                }
            }
            Picker(strings(.settingsTextSize), selection: $model.textSize) {
                ForEach(AppTextSize.allCases) { size in Text(strings(size.label)).tag(size) }
            }
            Divider()
            ApplicationSelectionView(model: model)
            InputOutputGuide(expanded: $model.showInputOutputGuide)
            Divider()
            Text(strings(.settingsDefaultFolder)).font(typography.section)
            Text(model.recordingRoot.path).font(typography.caption).foregroundStyle(.secondary).textSelection(
                .enabled)
            Button(strings(.settingsChangeFolder)) { model.chooseRecordingFolder() }.disabled(
                !model.canChangeRecordingFolder)
            if let issue = model.recordingFolderIssue {
                InlineIssueView(message: strings(issue.message), details: issue.details)
            }
            if !model.addedLibraryFolders.isEmpty {
                ForEach(model.addedLibraryFolders, id: \.self) { folder in
                    HStack {
                        Text(folder.path).font(typography.caption).foregroundStyle(.secondary).lineLimit(2)
                        Spacer()
                        Button {
                            model.removeLibraryFolder(folder)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.plain).accessibilityLabel(strings(.settingsRemoveFolder))
                    }
                }
            }
            Button(strings(.settingsAddFolder)) { model.addLibraryFolder() }.disabled(model.preview)
            Divider()
            LabeledContent(
                strings(.settingsVersion),
                value: AppBuildVersion(bundle: .main).display)
            Button(strings(.settingsSetup)) {
                showSetup = true
            }
            DisclosureGroup(strings(.settingsDevices)) {
                VStack(alignment: .leading, spacing: 12) {
                    DriverStatusRow(name: "Caller → Switchboard", available: model.callerDevice != nil)
                    DriverStatusRow(name: "Switchboard → Agent", available: model.agentInputDevice != nil)
                    DriverStatusRow(name: "Agent → Caller", available: model.replyDevice != nil)
                    HStack {
                        Button(strings(.settingsReinstall)) { Task { await model.installDrivers() } }
                        Button(strings(.settingsRemove), role: .destructive) {
                            Task { await model.installDrivers(remove: true) }
                        }
                    }.disabled(model.preview || model.installing || model.session.active)
                    if let issue = model.driverIssue {
                        InlineIssueView(message: strings(issue.message), details: issue.details)
                    }
                }
            }.disclosureGroupStyle(FullRowDisclosureStyle())
        }.font(typography.body)
            .sheet(isPresented: $showSetup) {
                SettingsSurface(width: 600, maximumHeight: 620) { SetupView(model: model) }
            }
    }
}

struct DriverStatusRow: View {
    @Environment(\.appTypography) private var typography
    @Environment(\.appStrings) private var strings
    let name: String
    let available: Bool

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(available ? Color.green : Color.red).frame(width: 7, height: 7)
                .accessibilityHidden(true)
            Text(name)
            Spacer()
            Text(strings(available ? .driverAvailable : .driverMissing))
                .foregroundStyle(.secondary)
        }
        .font(typography.caption)
        .accessibilityElement(children: .combine)
    }
}

extension View {
    fileprivate func setupGroup() -> some View {
        padding(.horizontal, 16)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }
}
