import BridgeCore
import SwiftUI
import TranscriptKit
import Translation

struct LanguageModelsView: View {
    @Environment(\.appStrings) private var strings
    @Environment(\.dismiss) private var dismiss
    let configuration: TranscriptConfiguration
    @ViewState private var states: [AudioSide: TranscriptSideState] = [:]
    @ViewState private var downloading = false
    @ViewState private var downloadTask: Task<Void, Never>?
    @ViewState private var error: String?
    @ViewState private var translation: TranslationSession.Configuration?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text(strings(.transcriptModels)).font(.title2.weight(.semibold))
                Spacer()
                Button(strings(downloading ? .actionCancel : .actionDone)) {
                    downloadTask?.cancel()
                    dismiss()
                }
            }
            ForEach(AudioSide.allCases, id: \.self) { side in
                let source = configuration.sourceLocaleIdentifier(for: side)
                let name = strings.locale.localizedString(forIdentifier: source) ?? source
                VStack(alignment: .leading, spacing: 10) {
                    Text((side == .caller ? strings(.roleCaller) : "Agent") + " · " + name).font(.headline)
                    if states[side]?.speech == .downloadRequired {
                        Button(strings(.transcriptDownloadSpeech)) { downloadSpeech() }.disabled(downloading)
                    }
                    if states[side]?.translation == .downloadRequired {
                        Button(strings(.transcriptDownloadTranslation)) {
                            translation = TranslationSession.Configuration(
                                source: Locale.Language(identifier: source),
                                target: Locale.Language(identifier: configuration.targetLocaleIdentifier))
                        }
                    }
                    if let state = states[side] {
                        Text(
                            strings(
                                state.speech == .unsupported || state.translation == .unsupported
                                    ? .transcriptUnsupportedPair
                                    : state.speech == .ready
                                        && (state.translation == .ready || state.translation == .notNeeded)
                                        ? .transcriptReady : .transcriptDownloadRequired)
                        )
                        .font(.system(size: 14)).foregroundStyle(.secondary)
                    }
                }
                if side == .caller { Divider() }
            }
            if downloading { ProgressView().controlSize(.small) }
            if let error { Text(error).foregroundStyle(.orange).font(.system(size: 14)) }
        }.padding(24).frame(width: 460)
            .onDisappear {
                downloadTask?.cancel()
                downloadTask = nil
            }
            .task { await refresh() }
            .translationTask(translation, action: prepareTranslation)
    }

    private func downloadSpeech() {
        downloading = true
        downloadTask = Task {
            defer {
                downloading = false
                downloadTask = nil
            }
            do {
                try await TranscriptCapabilities.installSpeechModels(configuration: configuration)
            } catch is CancellationError {} catch { self.error = strings.error(error) }
            await refresh()
        }
    }

    private func refresh() async {
        let result = await TranscriptCapabilities.check(configuration: configuration)
        if !Task.isCancelled { states = result.states }
    }

    nonisolated private func prepareTranslation(_ session: TranslationSession) async {
        let failure: String?
        do {
            try await session.prepareTranslation()
            failure = nil
        } catch { failure = error.localizedDescription }
        await MainActor.run {
            error = failure
            translation = nil
        }
        await refresh()
    }
}
