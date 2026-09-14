import BridgeCore
import SwiftUI

struct SessionHomeView: View {
    @Environment(\.appTypography) private var typography
    @Environment(\.appStrings) private var strings
    @Bindable var model: AppModel

    private var startHelp: TextKey {
        if model.installing { return .statusInstalling }
        if model.starting { return .statusConnecting }
        if model.requiresSetup { return .sessionSetupNeeded }
        return model.canStartSession ? .sessionStartHelp : .sessionAppsNeeded
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 18) {
                Text(strings(.sessionNew)).font(typography.title)
                TextField(strings(.sessionName), text: $model.sessionName)
                    .font(typography.panelTitle)
                    .accessibilityLabel(strings(.sessionName))
                    .sessionInput()
                TextField(strings(.sessionDescription), text: $model.sessionDescription, axis: .vertical)
                    .lineLimit(3...6).font(typography.body)
                    .accessibilityLabel(strings(.sessionDescription))
                    .sessionInput()
            }
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 12) {
                    application(model.routeProfile?.caller.name ?? strings(.roleCaller), icon: "phone")
                    Image(systemName: "arrow.left.arrow.right").foregroundStyle(.tertiary)
                    application(model.routeProfile?.agent.name ?? "Agent", icon: "waveform")
                    Spacer(minLength: 8)
                    IconButton("slider.horizontal.3", label: strings(.settingsApplications)) {
                        model.showSettings = true
                    }
                }
                Divider()
                ListeningView(model: model)
            }.padding(20).background(
                Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            HStack(spacing: 16) {
                Text(strings(startHelp))
                    .font(typography.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                Button {
                    if model.requiresSetup { model.showSetup = true } else { model.startSession() }
                } label: {
                    Label(
                        strings(model.requiresSetup ? .actionSetup : .actionStart),
                        systemImage: model.requiresSetup ? "slider.horizontal.3" : "play.fill"
                    )
                    .font(typography.section)
                    .frame(minWidth: 104, minHeight: 24)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .fixedSize()
                .disabled(
                    model.installing || model.starting || (!model.requiresSetup && !model.canStartSession))
            }
        }.frame(maxWidth: 720).frame(maxWidth: .infinity)
    }

    private func application(_ name: String, icon: String) -> some View {
        Label(name, systemImage: icon).font(typography.row)
    }
}

struct ActiveSessionView: View {
    @Environment(\.appTypography) private var typography
    @Environment(\.appStrings) private var strings
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        SessionHeading(
                            name: model.session.sessionName,
                            description: model.session.sessionDescription,
                            duration: model.session.duration)
                        if model.session.paused {
                            Label(
                                strings(
                                    model.session.pauseReason == .callerDisconnected
                                        ? .sessionDisconnected : .sessionPaused),
                                systemImage: "pause.circle"
                            ).font(typography.row).foregroundStyle(.orange)
                        }
                        LiveConversationWaveform(
                            caller: model.audio.callerWaveform, agent: model.audio.agentWaveform,
                            callerName: model.routeProfile?.caller.name,
                            agentName: model.routeProfile?.agent.name
                        )
                        .padding(.vertical, 12)
                        if let error = model.audio.callerError {
                            Label(
                                strings(.roleCaller) + ": " + strings.error(error),
                                systemImage: "exclamationmark.circle"
                            )
                            .font(typography.caption).foregroundStyle(.orange)
                        }
                        if let error = model.audio.agentError {
                            Label("Agent: " + strings.error(error), systemImage: "exclamationmark.circle")
                                .font(typography.caption).foregroundStyle(.orange)
                        }
                        if model.requiresSetup {
                            Button(strings(.actionSetup)) { model.showSetup = true }
                        }
                        Divider()
                        ListeningView(model: model)
                        Divider()
                        Button(strings(.routeDeviceHelp)) {
                            model.showInputOutputGuide = true
                            model.showSettings = true
                        }.buttonStyle(.link)
                    }.padding(24)
                }.frame(
                    minWidth: 300, idealWidth: 360, maxWidth: model.transcript.panelVisible ? 440 : .infinity)
                if model.transcript.panelVisible {
                    TranscriptPanel(model: model).frame(
                        minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            Divider()
            HStack(spacing: 18) {
                Toggle(
                    isOn: Binding(
                        get: { model.session.audioRecordingEnabled },
                        set: { enabled in
                            if enabled {
                                model.startRecording()
                            } else {
                                Task { await model.stopRecording() }
                            }
                        })
                ) {
                    Label(strings(.sessionRecording), systemImage: "record.circle")
                }.toggleStyle(.button).disabled(model.preview)
                Toggle(
                    isOn: Binding(
                        get: { model.session.transcriptionEnabled },
                        set: { model.setTranscriptionEnabled($0) })
                ) {
                    Label(strings(.sessionTranscription), systemImage: "captions.bubble")
                }.toggleStyle(.button)
                Spacer()
                if !model.session.closed {
                    Button(strings(model.session.paused ? .actionResume : .actionPause)) {
                        if model.session.paused { model.resume() } else { Task { await model.pause() } }
                    }.disabled(model.preview)
                }
                Button(strings(.actionEndSession)) { model.endSession() }
            }.controlSize(.large).disabled(model.session.busy || model.masterBusy || model.endingSession)
                .padding(.horizontal, 24).padding(.vertical, 16)
        }
    }
}

struct InputOutputGuide: View {
    @Environment(\.appTypography) private var typography
    @Environment(\.appStrings) private var strings

    @Binding var expanded: Bool

    var body: some View {
        DisclosureGroup(strings(.routeDeviceHelp), isExpanded: $expanded) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                GridRow {
                    Text(strings(.routeAgentMicrophone))
                    Text("Switchboard → Agent").textSelection(.enabled)
                }
                GridRow {
                    Text(strings(.routeCallerSpeaker))
                    Text("Caller → Switchboard").textSelection(.enabled)
                }
                GridRow {
                    Text(strings(.routeCallerMicrophone))
                    Text("Agent → Caller").textSelection(.enabled)
                }
            }.font(typography.caption).padding(.top, 12)
        }.font(typography.body).disclosureGroupStyle(FullRowDisclosureStyle())
    }
}

struct ApplicationSelectionView: View {
    @Environment(\.appTypography) private var typography
    @Environment(\.appStrings) private var strings
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(strings(.settingsApplications)).font(typography.section)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                selection(title: "Agent", application: model.routeProfile?.agent, forAgent: true)
                selection(
                    title: strings(.roleCaller), application: model.routeProfile?.caller, forAgent: false)
            }
        }.disabled(model.session.active || model.session.busy)
    }

    private func selection(title: String, application: ApplicationIdentity?, forAgent: Bool) -> some View {
        GridRow {
            Text(title)
            Menu(application?.name ?? strings(.settingsChooseApplication)) {
                Picker(
                    title,
                    selection: Binding(
                        get: { application?.id ?? "" },
                        set: { id in
                            if let candidate = model.applications.first(where: { $0.id == id }) {
                                model.selectApplication(candidate, forAgent: forAgent)
                            }
                        })
                ) {
                    if let application, !ApplicationCatalog.isSuggested(application, forAgent: forAgent) {
                        Text(strings(.settingsCurrentApplication, application.name)).tag(application.id)
                            .disabled(true)
                    }
                    ForEach(
                        model.applications.filter { ApplicationCatalog.isSuggested($0, forAgent: forAgent) }
                    ) { candidate in
                        Text(candidate.name).tag(candidate.id)
                    }
                }.pickerStyle(.inline).labelsHidden()
                Divider()
                Button(strings(.settingsChooseApplication)) { model.chooseApplication(forAgent: forAgent) }
            }.frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
                .help(application?.name ?? strings(.settingsChooseApplication))
        }
    }
}

extension View {
    fileprivate func sessionInput() -> some View {
        textFieldStyle(.plain).padding(16)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(0.1)))
    }
}
