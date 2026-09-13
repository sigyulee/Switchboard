import SwiftUI

struct ListeningView: View {
    @Environment(\.appStrings) private var strings
    @Bindable var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(strings(.monitorTitle), systemImage: "headphones").font(
                    .system(size: 17, weight: .semibold))
                Spacer()
                Picker(strings(.monitorDevice), selection: $model.preferredUID) {
                    Text(strings(.monitorChoose)).tag("")
                    if !model.preferredUID.isEmpty && model.preferredDevice == nil {
                        Text(strings(.monitorPrevious)).tag(model.preferredUID)
                    }
                    ForEach(model.outputs) { device in Text(device.name).tag(device.uid) }
                }.labelsHidden().frame(maxWidth: 220)
            }
            HStack(spacing: 24) {
                volume(strings(.monitorCaller), value: $model.callerVolume)
                volume("Agent", value: $model.agentVolume)
            }
            HStack(alignment: .top, spacing: 12) {
                Toggle(strings(.monitorFallback, model.preferredOutputName), isOn: $model.speakerFallback)
                    .toggleStyle(.switch).controlSize(.mini).font(.system(size: 14))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            if let error = model.audio.monitorError {
                Text(strings.error(error)).font(.system(size: 14)).foregroundStyle(.orange)
            }
        }
        .onChange(of: model.preferredUID) { model.refresh() }
        .onChange(of: model.speakerFallback) { model.refresh() }
        .onChange(of: model.callerVolume) { model.refresh() }
        .onChange(of: model.agentVolume) { model.refresh() }
    }
    private func volume(_ title: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.system(size: 14)).foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(value.wrappedValue * 100))%").font(.system(size: 14).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: 0...1).controlSize(.regular).accessibilityLabel(
                strings(.monitorVolume, title))
        }
    }
}
