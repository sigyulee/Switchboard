import BridgeCore
import SwiftUI

struct SessionHomeView: View {
    @Environment(\.appStrings) private var strings
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 18) {
                Text(strings(.sessionNew)).font(.system(size: 28, weight: .semibold))
                VStack(alignment: .leading, spacing: 12) {
                    TextField(strings(.sessionName), text: $model.sessionName)
                        .font(.system(size: 20, weight: .medium))
                    TextField(strings(.sessionDescription), text: $model.sessionDescription, axis: .vertical)
                        .lineLimit(2...4).font(.system(size: 16))
                }.textFieldStyle(.plain).padding(20)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.08)))
            }
            if !model.unfinishedSessions.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text(strings(.sessionUnfinished)).font(.system(size: 15, weight: .medium))
                    ForEach(model.unfinishedSessions, id: \.manifest.id) { draft in
                        Button {
                            model.openDraft(draft)
                        } label: {
                            HStack {
                                Label(draft.manifest.title, systemImage: "clock.arrow.circlepath")
                                Spacer()
                                Text(durationText(Double(draft.manifest.durationFrames) / 48_000))
                                    .monospacedDigit()
                            }
                        }.buttonStyle(.plain).font(.system(size: 14)).padding(.vertical, 6)
                    }
                }
            }
            HStack(spacing: 18) {
                application(model.routeProfile?.caller.name ?? "Caller", icon: "phone")
                Image(systemName: "arrow.left.arrow.right").foregroundStyle(.tertiary)
                application(model.routeProfile?.agent.name ?? "Agent", icon: "waveform")
                Spacer()
                Button {
                    model.showSettings = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .buttonStyle(.plain).accessibilityLabel(strings(.settingsApplications))
            }
            Divider()
            InputOutputGuide(model: model, confirm: true)
            ListeningView(model: model)
            HStack {
                if model.requiresSetup {
                    Button(strings(.actionSetup)) { model.showSetup = true }
                }
                Spacer()
                Button(strings(.actionStart)) { model.startSession() }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(!model.canStartSession)
            }
        }.frame(maxWidth: 720).frame(maxWidth: .infinity)
    }

    private func application(_ name: String, icon: String) -> some View {
        Label(name, systemImage: icon).font(.system(size: 16, weight: .medium))
    }
}

struct ActiveSessionView: View {
    @Environment(\.appStrings) private var strings
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(model.session.state?.name ?? "").font(.system(size: 24, weight: .semibold))
                                .textSelection(.enabled)
                            if let description = model.session.state?.description, !description.isEmpty {
                                Text(description).font(.system(size: 15)).foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                        if model.session.paused {
                            Label(
                                strings(
                                    model.session.state?.pauseReason == .callerDisconnected
                                        ? .sessionDisconnected : .sessionPaused),
                                systemImage: "pause.circle"
                            ).font(.system(size: 15, weight: .medium)).foregroundStyle(.orange)
                        }
                        LiveConversationWaveform(
                            caller: model.audio.callerWaveform, agent: model.audio.agentWaveform
                        )
                        .padding(.vertical, 12)
                        if let error = model.audio.callerError {
                            Label(
                                strings(.roleCaller) + ": " + strings.error(error),
                                systemImage: "exclamationmark.circle"
                            )
                            .font(.system(size: 14)).foregroundStyle(.orange)
                        }
                        if let error = model.audio.agentError {
                            Label("Agent: " + strings.error(error), systemImage: "exclamationmark.circle")
                                .font(.system(size: 14)).foregroundStyle(.orange)
                        }
                        if model.requiresSetup {
                            Button(strings(.actionSetup)) { model.showSetup = true }
                        }
                        Divider()
                        ListeningView(model: model)
                        Divider()
                        InputOutputGuide(model: model, confirm: false)
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
                        get: { model.session.state?.audioRecording == true },
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
                        get: { model.session.state?.transcription == true },
                        set: { model.setTranscriptionEnabled($0) })
                ) {
                    Label(strings(.sessionTranscription), systemImage: "captions.bubble")
                }.toggleStyle(.button).disabled(model.preview)
                Text(durationText(model.session.duration)).font(
                    .system(size: 20, weight: .light).monospacedDigit())
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
    @Environment(\.appStrings) private var strings
    @Bindable var model: AppModel
    let confirm: Bool

    var body: some View {
        DisclosureGroup(strings(.routeDeviceHelp)) {
            VStack(alignment: .leading, spacing: 12) {
                LabeledContent(strings(.routeAgentMicrophone), value: "Switchboard → Agent")
                LabeledContent(strings(.routeCallerSpeaker), value: "Caller → Switchboard")
                LabeledContent(strings(.routeCallerMicrophone), value: "Agent → Caller")
            }.font(.system(size: 14)).padding(.top, 12)
        }.font(.system(size: 15))
        if confirm {
            Toggle(
                strings(.settingsCallerConfirmed),
                isOn: Binding(
                    get: { model.routeProfile?.callerDevicesConfirmed == true },
                    set: { model.confirmCallerDevices($0) })
            )
            .font(.system(size: 14)).toggleStyle(.checkbox)
        }
    }
}

struct ApplicationSelectionView: View {
    @Environment(\.appStrings) private var strings
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(strings(.settingsApplications)).font(.headline)
            selection(title: "Agent", application: model.routeProfile?.agent, forAgent: true)
            selection(title: strings(.roleCaller), application: model.routeProfile?.caller, forAgent: false)
        }.disabled(model.session.active || model.session.busy)
    }

    private func selection(title: String, application: ApplicationIdentity?, forAgent: Bool) -> some View {
        LabeledContent(title) {
            Menu(application?.name ?? strings(.settingsChooseApplication)) {
                ForEach(model.applications) { candidate in
                    Button(candidate.name) { model.selectApplication(candidate, forAgent: forAgent) }
                }
                Divider()
                Button(strings(.settingsChooseApplication)) { model.chooseApplication(forAgent: forAgent) }
            }
        }
    }
}
