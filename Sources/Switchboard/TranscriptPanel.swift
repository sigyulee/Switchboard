import BridgeCore
import SwiftUI
import Translation

struct TranscriptPanel: View {
    @Environment(\.appTypography) private var typography
    @Environment(\.appStrings) private var strings
    @Environment(AppFindController.self) private var findController
    @Bindable var model: AppModel
    @ViewState private var fallbackTranscriptID = UUID()
    private var transcriptID: UUID { model.session.sessionID ?? fallbackTranscriptID }
    @ViewState private var translationDownload: TranslationSession.Configuration?
    @ViewState private var translationDownloadID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(strings(.transcriptTitle)).font(typography.panelTitle)
                Spacer()
                if model.transcript.catchingUp {
                    ProgressView().controlSize(.small).accessibilityLabel(strings(.transcriptCatchingUp))
                }
                if !model.transcript.showConfiguration {
                    IconButton("magnifyingglass", label: strings(.transcriptSearch)) {
                        findController.findTranscript(owner: transcriptID)
                    }
                }
                IconButton("slider.horizontal.3", label: strings(.transcriptConfigure)) {
                    if model.transcript.showConfiguration {
                        model.transcript.showConfiguration = false
                    } else {
                        model.transcript.openConfiguration()
                    }
                }
            }.padding(24)
            HStack(alignment: .top, spacing: 20) {
                engineStatus(strings(.transcriptSpeechEngine), kind: .speech)
                engineStatus(strings(.transcriptTranslationEngine), kind: .translation)
            }.padding(.horizontal, 24).padding(.bottom, 20)
            Divider()
            if model.transcript.showConfiguration {
                configuration
            } else {
                TranscriptMessages(
                    transcriptID: transcriptID, entries: model.transcript.entries,
                    isProcessing: model.transcript.isProcessing
                ).id(transcriptID)
            }
            if let error = model.transcript.error,
                !model.transcript.states.values.contains(where: {
                    [.failed, .resourceLimit].contains($0.speech)
                        || [.failed, .resourceLimit].contains($0.translation)
                })
            {
                InlineIssueView(message: strings(.transcriptOperationFailure), details: error).padding(20)
            }
            if !model.transcript.gaps.isEmpty {
                Label(strings(.transcriptGaps), systemImage: "exclamationmark.circle")
                    .font(typography.caption).foregroundStyle(.secondary).padding(20)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .task { if !model.preview { await model.transcript.loadLanguages() } }
        .translationTask(translationDownload, action: prepareTranslation)
    }

    nonisolated private func prepareTranslation(_ session: TranslationSession) async {
        let request = await MainActor.run { (translationDownloadID, model.transcript.configuration) }
        guard let requestID = request.0, let configuration = request.1 else { return }
        let message: String?
        do {
            try await session.prepareTranslation()
            message = nil
        } catch { message = error.localizedDescription }
        guard !Task.isCancelled else { return }
        await MainActor.run {
            guard translationDownloadID == requestID, model.transcript.configuration == configuration else {
                return
            }
            if let message {
                model.transcript.translationPreparationFailed(message, configuration: configuration)
            } else {
                model.transcript.refreshCapabilities()
            }
            translationDownload = nil
            translationDownloadID = nil
        }
    }

    private func changeLanguage(_ value: String, setting: TranscriptController.LanguageSetting) {
        translationDownload = nil
        translationDownloadID = nil
        model.transcript.setLanguage(value, for: setting, session: model.session)
    }

    private var configuration: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                languagePicker(
                    strings(.transcriptYourLanguage),
                    selection: Binding(
                        get: { model.transcript.targetLanguage },
                        set: { changeLanguage($0, setting: .target) }), source: false)
                languagePicker(
                    strings(.transcriptAgentLanguage),
                    selection: Binding(
                        get: { model.transcript.agentLanguage }, set: { changeLanguage($0, setting: .agent) }),
                    source: true)
                languagePicker(
                    strings(.transcriptCallerLanguage),
                    selection: Binding(
                        get: { model.transcript.callerLanguage },
                        set: { changeLanguage($0, setting: .caller) }), source: true)
                Divider()
                if model.transcript.needsSpeechDownload {
                    Button(strings(.transcriptDownloadSpeech)) { model.transcript.downloadSpeech() }
                        .disabled(model.transcript.busy || model.transcript.changingConfiguration)
                }
                ForEach(AudioSide.allCases, id: \.self) { side in
                    if model.transcript.needsTranslationDownload(for: side) {
                        Button {
                            guard let configuration = model.transcript.configuration else { return }
                            translationDownloadID = UUID()
                            translationDownload = TranslationSession.Configuration(
                                source: Locale.Language(
                                    identifier: configuration.sourceLocaleIdentifier(for: side)),
                                target: Locale.Language(identifier: configuration.targetLocaleIdentifier))
                        } label: {
                            Text(
                                strings(.transcriptDownloadTranslation) + " · "
                                    + (side == .caller ? strings(.roleCaller) : "Agent"))
                        }.disabled(model.transcript.busy || model.transcript.changingConfiguration)
                    }
                }
                Button(strings(.actionStart)) { model.transcript.start(session: model.session) }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(!model.transcript.canStart || !model.session.running || model.preview)
                Button(strings(.transcriptRecordOnly)) {
                    translationDownload = nil
                    translationDownloadID = nil
                    model.transcript.recordOnly(session: model.session)
                }.buttonStyle(.plain).foregroundStyle(.secondary)
            }.padding(24)
        }
    }

    private func languagePicker(_ title: String, selection: Binding<String>, source: Bool) -> some View {
        let choices = source ? model.transcript.speechLanguages : model.transcript.translationLanguages
        let canonicalSelection = Binding(
            get: {
                choices.first(where: { localeKey($0) == localeKey(selection.wrappedValue) })
                    ?? selection.wrappedValue
            },
            set: { value in
                if localeKey(value) != localeKey(selection.wrappedValue) { selection.wrappedValue = value }
            })
        return VStack(alignment: .leading, spacing: 8) {
            Text(title).font(typography.caption.weight(.medium)).foregroundStyle(.secondary)
            Picker(title, selection: canonicalSelection) {
                Text(strings(.transcriptChooseLanguage)).tag("")
                if !selection.wrappedValue.isEmpty,
                    !choices.contains(where: { localeKey($0) == localeKey(selection.wrappedValue) })
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

    private func localeKey(_ identifier: String) -> String {
        identifier.replacingOccurrences(of: "_", with: "-").lowercased()
    }

    private func languageName(_ identifier: String) -> String {
        strings.locale.localizedString(forIdentifier: identifier) ?? identifier
    }
    private func translatable(_ identifier: String) -> Bool {
        model.transcript.translationLanguages.contains {
            TranscriptConfiguration.languageKey($0) == TranscriptConfiguration.languageKey(identifier)
        }
    }

    private func engineStatus(_ title: String, kind: TranscriptEnginePresentation.Kind) -> some View {
        let presentation = TranscriptEnginePresentation(kind: kind, states: model.transcript.states)
        let state = presentation.state
        let color: Color =
            switch state {
            case .ready: .green
            case .downloadRequired: .orange
            case .failed, .resourceLimit, .unsupported: .red
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
            Text(title).font(typography.caption).foregroundStyle(.secondary)
            Label {
                Text(strings(label)).font(typography.caption.weight(.medium))
            } icon: {
                Circle().fill(color).frame(width: 7, height: 7)
            }
            if let issue = presentation.issue {
                InlineIssueView(message: strings(issue), details: presentation.details)
            } else if state == .unsupported {
                Text(strings(kind == .speech ? .transcriptNoSpeech : .transcriptUnsupportedPair))
                    .font(typography.caption).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
