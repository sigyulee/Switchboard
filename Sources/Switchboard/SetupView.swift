import BridgeCore
import SwiftUI

struct SetupView: View {
    @Environment(\.appStrings) private var strings
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text(strings(.setupTitle)).font(.system(size: 28, weight: .semibold))
                }
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                }.buttonStyle(.plain).accessibilityLabel(strings(.actionClose))
            }
            SetupRow(
                number: 1, title: strings(.setupDevices), detail: "Phone → Agent\nChrome → Phone",
                ready: model.driversReady
            ) {
                Button(
                    model.installing
                        ? strings(.setupInstalling)
                        : model.driversReady ? strings(.setupInstalled) : strings(.setupInstall)
                ) {
                    Task { await model.installDrivers() }
                }.disabled(model.installing || model.driversReady || model.preview)
            }
            if !model.driversReady {
                Text(strings(.setupInstallHelp))
                    .font(.system(size: 14)).foregroundStyle(.secondary).fixedSize(
                        horizontal: false, vertical: true)
            }
            Divider()
            SetupRow(
                number: 2, title: strings(.setupMicrophone), detail: strings(.setupMicrophoneHelp),
                ready: model.microphoneAllowed
            ) {
                Button(model.microphoneAllowed ? strings(.setupAllowed) : strings(.setupRequestMicrophone)) {
                    model.requestMicrophone()
                }
                .disabled(model.microphoneAllowed || model.preview)
            }
            SetupRow(
                number: 3, title: strings(.setupChrome), detail: strings(.setupChromeHelp),
                ready: model.chromeAudioConfirmed
            ) {
                Button(
                    model.captureAccessRequested ? strings(.setupRequestAgain) : strings(.setupRequestAudio)
                ) { model.requestChromeAccess() }
                .disabled(model.preview || model.captureRequestInProgress)
            }
            if model.captureAccessRequested && !model.chromeAudioConfirmed {
                HStack {
                    Text(strings(.setupPending))
                        .font(.system(size: 14)).foregroundStyle(.secondary)
                    Button(strings(.setupSystemSettings)) { model.openAudioPrivacy() }.disabled(model.preview)
                }
            }
            Divider()
            HStack {
                Spacer()
                Button(strings(.actionDone)) { dismiss() }.buttonStyle(.borderedProminent).keyboardShortcut(
                    .defaultAction)
            }
        }
    }
}

struct SetupRow<Control: View>: View {
    @Environment(\.appStrings) private var strings
    let number: Int
    let title: String
    let detail: String
    let ready: Bool
    @ViewBuilder var control: Control
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                Circle().fill(ready ? Color.green.opacity(0.12) : Color.primary.opacity(0.06))
                if ready {
                    Image(systemName: "checkmark").foregroundStyle(.green)
                } else {
                    Text("\(number)").foregroundStyle(.secondary)
                }
            }.font(.system(size: 14, weight: .semibold)).frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 16, weight: .medium))
                Text(detail).font(.system(size: 14)).foregroundStyle(.secondary).fixedSize(
                    horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            control.controlSize(.regular).font(.system(size: 15))
        }
    }
}

struct SettingsView: View {
    @Environment(\.appStrings) private var strings
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text(strings(.navigationSettings)).font(.title2.weight(.semibold))
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
            Divider()
            Text(strings(.settingsFolder)).font(.headline)
            Text(model.recordingRoot.path).font(.system(size: 14)).foregroundStyle(.secondary).textSelection(
                .enabled)
            Button(strings(.settingsChangeFolder)) { model.chooseRecordingFolder() }.disabled(
                model.preview || model.isRecording)
            Divider()
            LabeledContent(
                strings(.settingsVersion),
                value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                    ?? "—")
            Button(strings(.settingsSetup)) {
                dismiss()
                model.showSetup = true
            }
            DisclosureGroup(strings(.settingsDevices)) {
                VStack(alignment: .leading, spacing: 12) {
                    DriverStatusRow(name: "Phone → Agent", available: model.callerDevice != nil)
                    DriverStatusRow(name: "Chrome → Phone", available: model.replyDevice != nil)
                    HStack {
                        Button(strings(.settingsReinstall)) { Task { await model.installDrivers() } }
                        Button(strings(.settingsRemove), role: .destructive) {
                            Task { await model.installDrivers(remove: true) }
                        }
                    }.disabled(model.preview || model.installing || model.isRecording)
                }.padding(.top, 12)
            }
        }.font(.system(size: 15))
    }
}

struct DriverStatusRow: View {
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
        .font(.system(size: 14))
        .accessibilityElement(children: .combine)
    }
}
