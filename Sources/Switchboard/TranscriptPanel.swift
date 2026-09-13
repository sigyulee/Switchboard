import BridgeCore
import SwiftUI
import Translation

struct TranscriptPanel: View {
    @Environment(\.appStrings) private var strings
    @Bindable var model: AppModel
    @ViewState private var translationDownload: TranslationSession.Configuration?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(strings(.transcriptTitle)).font(.system(size: 18, weight: .semibold))
                Spacer()
                if model.transcript.catchingUp {
                    ProgressView().controlSize(.small).accessibilityLabel(strings(.transcriptCatchingUp))
                }
                Button {
                    model.transcript.showConfiguration.toggle()
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }.buttonStyle(.plain).accessibilityLabel(strings(.transcriptConfigure))
            }.padding(24)
            HStack(spacing: 20) {
                engineStatus(
                    strings(.transcriptSpeechEngine), states: model.transcript.states.values.map(\.speech))
                engineStatus(
                    strings(.transcriptTranslationEngine),
                    states: model.transcript.states.values.map(\.translation))
            }.padding(.horizontal, 24).padding(.bottom, 20)
            Divider()
            if model.transcript.showConfiguration {
                configuration
            } else {
                TranscriptMessages(entries: model.transcript.entries)
            }
            if let error = model.transcript.error {
                Text(error).font(.system(size: 14)).foregroundStyle(.orange).padding(20)
            }
            if !model.transcript.gaps.isEmpty {
                Label(strings(.transcriptGaps), systemImage: "exclamationmark.circle")
                    .font(.system(size: 13)).foregroundStyle(.secondary).padding(20)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .task { if !model.preview { await model.transcript.loadLanguages() } }
        .onChange(of: model.transcript.callerLanguage) { model.transcript.refreshCapabilities() }
        .onChange(of: model.transcript.agentLanguage) { model.transcript.refreshCapabilities() }
        .onChange(of: model.transcript.targetLanguage) { model.transcript.refreshCapabilities() }
        .translationTask(translationDownload, action: prepareTranslation)
    }

    nonisolated private func prepareTranslation(_ session: TranslationSession) async {
        let message: String?
        do {
            try await session.prepareTranslation()
            message = nil
        } catch { message = error.localizedDescription }
        await MainActor.run {
            model.transcript.error = message
            model.transcript.refreshCapabilities()
            translationDownload = nil
        }
    }

    private var configuration: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                languagePicker(
                    strings(.transcriptYourLanguage),
                    selection: Binding(
                        get: { model.transcript.targetLanguage },
                        set: { model.transcript.targetLanguage = $0 }), source: false)
                languagePicker(
                    strings(.transcriptAgentLanguage),
                    selection: Binding(
                        get: { model.transcript.agentLanguage }, set: { model.transcript.agentLanguage = $0 }),
                    source: true)
                languagePicker(
                    strings(.transcriptCallerLanguage),
                    selection: Binding(
                        get: { model.transcript.callerLanguage },
                        set: { model.transcript.callerLanguage = $0 }), source: true)
                Divider()
                if model.transcript.needsSpeechDownload {
                    Button(strings(.transcriptDownloadSpeech)) { model.transcript.downloadSpeech() }
                }
                ForEach(AudioSide.allCases, id: \.self) { side in
                    if model.transcript.states[side]?.translation == .downloadRequired {
                        Button {
                            guard let configuration = model.transcript.configuration else { return }
                            translationDownload = TranslationSession.Configuration(
                                source: Locale.Language(
                                    identifier: configuration.sourceLocaleIdentifier(for: side)),
                                target: Locale.Language(identifier: configuration.targetLocaleIdentifier))
                        } label: {
                            Text(
                                strings(.transcriptDownloadTranslation) + " · "
                                    + (side == .caller ? strings(.roleCaller) : "Agent"))
                        }
                    }
                }
                if model.transcript.states.values.contains(where: { $0.translation == .unsupported }) {
                    Text(strings(.transcriptUnsupportedPair)).font(.system(size: 14)).foregroundStyle(
                        .secondary)
                }
                if !model.transcript.states.isEmpty,
                    model.transcript.states.values.allSatisfy({ $0.speech == .unsupported })
                {
                    Text(strings(.transcriptNoSpeech)).font(.system(size: 14)).foregroundStyle(.secondary)
                }
                Button(strings(.actionStart)) { model.transcript.start(session: model.session) }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(!model.transcript.canStart || !model.session.running || model.preview)
                Button(strings(.transcriptRecordOnly)) { model.transcript.panelVisible = false }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }.padding(24)
                .disabled(model.transcript.busy || model.session.state?.transcription == true)
        }
    }

    private func languagePicker(_ title: String, selection: Binding<String>, source: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 14, weight: .medium)).foregroundStyle(.secondary)
            Picker(title, selection: selection) {
                Text(strings(.transcriptChooseLanguage)).tag("")
                if !selection.wrappedValue.isEmpty,
                    !(source ? model.transcript.speechLanguages : model.transcript.translationLanguages)
                        .contains(selection.wrappedValue)
                {
                    Text(languageName(selection.wrappedValue)).tag(selection.wrappedValue)
                }
                if source {
                    Section(strings(.transcriptBoth)) {
                        ForEach(model.transcript.speechLanguages.filter(translatable), id: \.self) {
                            language in
                            Text(languageName(language)).tag(language)
                        }
                    }
                    Section(strings(.transcriptOnly)) {
                        ForEach(model.transcript.speechLanguages.filter { !translatable($0) }, id: \.self) {
                            language in
                            Text(languageName(language)).tag(language)
                        }
                    }
                } else {
                    ForEach(model.transcript.translationLanguages, id: \.self) { language in
                        Text(languageName(language)).tag(language)
                    }
                }
            }.labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func languageName(_ identifier: String) -> String {
        strings.locale.localizedString(forIdentifier: identifier) ?? identifier
    }
    private func translatable(_ identifier: String) -> Bool {
        model.transcript.translationLanguages.contains {
            TranscriptConfiguration.languageKey($0) == TranscriptConfiguration.languageKey(identifier)
        }
    }

    private func engineStatus(_ title: String, states: [TranscriptModelState]) -> some View {
        let state =
            states.first(where: { [.failed, .resourceLimit].contains($0) })
            ?? states.first(where: { [.downloadRequired, .unsupported].contains($0) })
            ?? states.first
        let color: Color =
            switch state {
            case .ready: .green
            case .downloadRequired, .resourceLimit: .orange
            case .failed, .unsupported: .red
            default: .secondary
            }
        let label: TextKey =
            switch state {
            case .ready: .transcriptReady
            case .notNeeded: .transcriptNotNeeded
            case .downloadRequired: .transcriptDownloadRequired
            case .unsupported: .transcriptUnsupported
            case .resourceLimit: .transcriptResourceLimit
            case .failed: .transcriptFailed
            case .stopped: .transcriptStopped
            default: .transcriptWaiting
            }
        return VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 13)).foregroundStyle(.secondary)
            Label {
                Text(strings(label)).font(.system(size: 14, weight: .medium))
            } icon: {
                Circle().fill(color).frame(width: 7, height: 7)
            }
        }
    }
}

struct TranscriptMessages: View {
    @Environment(\.appStrings) private var strings
    let entries: [TranscriptEntry]
    var seek: ((Double) -> Void)? = nil
    @ViewState private var followsLatest = true
    @ViewState private var visibleCount = 100

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 16) {
                    if entries.count > visibleCount {
                        Button {
                            visibleCount += 100
                        } label: {
                            Image(systemName: "chevron.up")
                        }
                        .accessibilityLabel(strings(.transcriptEarlierMessages))
                    }
                    if entries.isEmpty {
                        Text(strings(.transcriptNoMessages)).font(.system(size: 15)).foregroundStyle(
                            .tertiary
                        )
                        .frame(maxWidth: .infinity).padding(.top, 48)
                    }
                    ForEach(entries.suffix(visibleCount)) { entry in
                        TranscriptMessage(entry: entry, seek: seek).id(entry.id)
                    }
                    Color.clear.frame(height: 1).id("latest")
                        .onAppear { followsLatest = true }
                        .onDisappear { followsLatest = false }
                }.padding(24)
            }
            .onChange(of: entries) {
                if followsLatest { proxy.scrollTo("latest", anchor: .bottom) }
            }
            .overlay(alignment: .bottom) {
                if !followsLatest, !entries.isEmpty {
                    Button(strings(.transcriptNewMessages)) {
                        followsLatest = true
                        proxy.scrollTo("latest", anchor: .bottom)
                    }.buttonStyle(.bordered).padding(12)
                }
            }
        }
    }
}

struct TranscriptMessage: View {
    @Environment(\.appStrings) private var strings
    let entry: TranscriptEntry
    var seek: ((Double) -> Void)? = nil
    var body: some View {
        HStack {
            if entry.side == .agent { Spacer(minLength: 32) }
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text(entry.side == .agent ? "Agent" : strings(.roleCaller)).font(
                        .system(size: 12, weight: .semibold))
                    if let seek {
                        Button(durationText(Double(entry.startFrame) / 48_000)) {
                            seek(Double(entry.startFrame) / 48_000)
                        }
                        .buttonStyle(.plain).font(.system(size: 12).monospacedDigit()).foregroundStyle(
                            .secondary)
                    } else {
                        Text(durationText(Double(entry.startFrame) / 48_000)).font(
                            .system(size: 12).monospacedDigit()
                        ).foregroundStyle(.secondary)
                    }
                }
                Text(entry.original).font(.system(size: 16)).foregroundStyle(
                    entry.isFinal ? .primary : .secondary)
                if let translation = entry.translation {
                    Divider().opacity(0.5)
                    Text(translation).font(.system(size: 15)).foregroundStyle(.secondary)
                }
            }
            .textSelection(.enabled).padding(16)
            .background(
                entry.side == .agent ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.045),
                in: RoundedRectangle(cornerRadius: 12)
            )
            .frame(maxWidth: 500, alignment: .leading)
            if entry.side == .caller { Spacer(minLength: 32) }
        }
    }
}
