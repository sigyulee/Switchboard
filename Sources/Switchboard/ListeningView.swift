import SwiftUI

struct ListeningView: View {
    @Environment(\.appTypography) private var typography
    @Environment(\.appStrings) private var strings
    @Bindable var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(strings(.monitorTitle), systemImage: "headphones").font(
                    typography.section)
                Spacer()
                Picker(strings(.monitorDevice), selection: $model.preferredUID) {
                    Text(strings(.monitorChoose)).tag("")
                    if !model.preferredUID.isEmpty && model.preferredDevice == nil {
                        Text(strings(.monitorDisconnected, model.preferredOutputName)).tag(model.preferredUID)
                    }
                    ForEach(model.outputs) { device in Text(device.name).tag(device.uid) }
                }.labelsHidden().frame(maxWidth: 220)
            }
            HStack(spacing: 24) {
                volume(strings(.monitorCaller), value: $model.callerVolume)
                volume("Agent", value: $model.agentVolume)
            }
            if !model.preferredUID.isEmpty && model.preferredDevice?.builtIn != true {
                HStack(alignment: .top, spacing: 12) {
                    Toggle(strings(.monitorFallback, model.preferredOutputName), isOn: $model.speakerFallback)
                        .toggleStyle(.switch).controlSize(.mini).font(typography.body)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
            if let error = model.monitorError {
                InlineIssueView(message: strings(.errorConnectDevice), details: strings.error(error))
            }
        }
        .onChange(of: model.preferredUID) { model.refreshMonitoring() }
        .onChange(of: model.speakerFallback) { model.refreshMonitoring() }
        .onChange(of: model.callerVolume) { model.refreshMonitoring() }
        .onChange(of: model.agentVolume) { model.refreshMonitoring() }
    }
    private func volume(_ title: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(typography.body).foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(value.wrappedValue * 100))%").font(typography.body.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: 0...1).controlSize(.regular).accessibilityLabel(
                strings(.monitorVolume, title))
        }
    }
}
