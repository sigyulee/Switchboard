import AppKit
import BridgeCore
import RecorderKit
import SwiftUI

struct LibraryView: View {
    @Environment(\.appTypography) private var typography
    @Environment(\.appStrings) private var strings
    @Environment(AppFindController.self) private var findController
    @Bindable var model: AppModel
    @ViewState private var query = ""
    @FocusState private var searchFocused: Bool
    @FocusState private var listFocused: Bool
    private var items: [RecordingItem] {
        query.isEmpty
            ? model.recordings
            : model.recordings.filter { $0.manifest.title.localizedCaseInsensitiveContains(query) }
    }
    private var drafts: [StoredSession] {
        model.unfinishedSessions.filter {
            query.isEmpty || $0.manifest.title.localizedCaseInsensitiveContains(query)
        }
    }
    var body: some View {
        LibrarySplitView(sidebarWidth: $model.librarySidebarWidth) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(strings(.navigationRecordings)).font(typography.title)
                    Text("\(model.recordings.count + model.unfinishedSessions.count)")
                        .font(typography.title.weight(.regular).monospacedDigit()).foregroundStyle(.secondary)
                    Spacer()
                }.accessibilityElement(children: .combine).padding(.horizontal, 20).padding(.top, 20)
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                    TextField(strings(.librarySearch), text: $query).textFieldStyle(.plain)
                        .focused($searchFocused).focusEffectDisabled().accessibilityLabel(
                            strings(.librarySearch))
                }.font(typography.body).padding(10)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8).strokeBorder(
                            Color(nsColor: .separatorColor), lineWidth: 1)
                    }.padding(16)
                if items.isEmpty && drafts.isEmpty {
                    Text(strings(query.isEmpty ? .libraryEmpty : .libraryNoResults))
                        .font(typography.body).foregroundStyle(.secondary).padding(20)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    recordingList
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } detail: {
            Group {
                if model.openingDraft {
                    ProgressView(strings(.sessionOpening)).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if model.session.closed {
                    ClosedSessionView(model: model)
                } else if let item = model.selectedItem {
                    detail(item).font(typography.body).controlSize(.large).padding(20)
                } else {
                    Text(strings(.librarySelectRecording)).font(typography.body).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }.frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: searchFocused) { if searchFocused { findController.focusLibrary() } }
        .onChange(of: listFocused) { if listFocused { findController.focusLibrary() } }
        .sheet(
            isPresented: Binding(
                get: { model.storedProcessing.requiredModels != nil },
                set: { if !$0 { model.storedProcessing.requiredModels = nil } })
        ) {
            if let configuration = model.storedProcessing.requiredModels {
                LanguageModelsView(configuration: configuration)
            }
        }
        .task(id: model.recordingSearchRequested) {
            guard model.recordingSearchRequested else { return }
            await Task.yield()
            guard !Task.isCancelled, model.recordingSearchRequested else { return }
            searchFocused = true
            model.recordingSearchRequested = false
        }
    }

    private var recordingList: some View {
        let visibleDrafts = drafts
        let visibleItems = items
        let selectedID = model.selectedRecordingID
        return List(selection: Binding(get: { model.selectedRecordingID }, set: selectRecording)) {
            if !visibleDrafts.isEmpty {
                sectionHeader(.sessionUnfinished, first: true)
                ForEach(Array(visibleDrafts.enumerated()), id: \.element.manifest.id) { index, draft in
                    LibraryRecordingRow(
                        title: draft.manifest.title, date: draft.manifest.createdAt,
                        duration: Double(draft.manifest.durationFrames) / 48_000,
                        systemImage: "clock.arrow.circlepath", saved: false,
                        selected: draft.manifest.id == selectedID,
                        showsSeparator: index + 1 < visibleDrafts.count
                            && draft.manifest.id != selectedID
                            && visibleDrafts[index + 1].manifest.id != selectedID
                    ) {
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary).frame(
                            width: typography.controlSide, height: typography.controlSide
                        ).accessibilityHidden(true)
                    }.tag(draft.manifest.id)
                        .contextMenu {
                            Button(strings(.libraryRename)) { model.renameDraft(draft) }
                                .disabled(!model.canRenameDraft(draft))
                        }
                        .selectionDisabled(model.session.active || model.starting || model.session.busy)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 0))
                }
            }
            if !visibleItems.isEmpty {
                sectionHeader(.librarySavedSessions, first: visibleDrafts.isEmpty)
                ForEach(Array(visibleItems.enumerated()), id: \.element.id) { index, item in
                    LibraryRecordingRow(
                        title: item.manifest.title, date: item.manifest.createdAt,
                        duration: item.manifest.duration,
                        systemImage: item.manifest.status == .complete
                            ? "waveform" : "clock.arrow.circlepath",
                        saved: true, selected: item.id == selectedID,
                        showsSeparator: index + 1 < visibleItems.count && item.id != selectedID
                            && visibleItems[index + 1].id != selectedID
                    ) {
                        RecordingInfoButton(item: item)
                    }.tag(item.id)
                        .contextMenu {
                            Button(strings(.libraryRename)) { model.rename(item) }
                                .disabled(
                                    !model.canEdit(item) || model.exportBusy
                                        || model.libraryMutationTask != nil)
                        }
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 0))
                }
            }
        }.listStyle(.inset).focusable().focused($listFocused).focusEffectDisabled()
            .onMoveCommand { direction in
                if direction == .up { moveSelection(by: -1) }
                if direction == .down { moveSelection(by: 1) }
            }
            .disabled(model.openingDraft || model.endingSession)
    }

    private func moveSelection(by offset: Int) {
        let draftIDs =
            model.session.active || model.starting || model.session.busy
            ? [] : drafts.map(\.manifest.id)
        let ids = draftIDs + items.map(\.id)
        guard !ids.isEmpty else { return }
        let index = model.selectedRecordingID.flatMap { ids.firstIndex(of: $0) }
        let next =
            index.map { min(max($0 + offset, 0), ids.count - 1) }
            ?? (offset > 0 ? 0 : ids.count - 1)
        selectRecording(ids[next])
    }

    private func selectRecording(_ id: UUID?) {
        findController.focusLibrary()
        listFocused = true
        guard !model.openingDraft, !model.endingSession, id != model.selectedRecordingID else { return }
        if let draft = model.unfinishedSessions.first(where: { $0.manifest.id == id }) {
            guard !model.session.active, !model.starting, !model.session.busy else { return }
            if model.session.closed { model.closeSessionView() }
            model.selectedRecordingID = id
            model.openDraft(draft)
        } else {
            if model.session.closed { model.closeSessionView() }
            model.selectedRecordingID = id
        }
    }

    private func sectionHeader(_ key: TextKey, first: Bool) -> some View {
        Text(strings(key)).font(typography.section)
            .foregroundStyle(.secondary).textCase(nil)
            .padding(.top, first ? 8 : 28).padding(.bottom, 8)
            .accessibilityAddTraits(.isHeader)
            .selectionDisabled().listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
    }

    private func actionsUnavailable(for item: RecordingItem) -> Bool {
        model.exportBusy || model.playback.preparing || model.preview
            || model.libraryMutationTask != nil || item.directory == model.recordingURL
    }

    private func exportMenu(_ item: RecordingItem) -> some View {
        Menu {
            Button(strings(.libraryExportAll)) { model.exportAll(item) }
            Divider()
            Button(strings(.libraryExportMix)) { model.export(item) }
            Button(strings(.libraryExportText)) { model.exportTranscript(item) }
            Button(strings(.libraryExportCaller)) { model.export(item, side: .caller) }
            Button(strings(.libraryExportAgent)) { model.export(item, side: .agent) }
        } label: {
            ControlIcon(systemName: "paperplane").hoverBackground()
        }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel(strings(model.exportBusy ? .libraryExporting : .actionExport))
            .help(strings(model.exportBusy ? .libraryExporting : .actionExport))
    }

    @ViewBuilder private func detail(_ item: RecordingItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.manifest.title).font(typography.panelTitle).lineLimit(2).help(item.manifest.title)
                Spacer(minLength: 12)
                IconButton("square.and.pencil", label: strings(.libraryRename)) { model.rename(item) }
                    .disabled(!model.canEdit(item) || model.exportBusy || model.libraryMutationTask != nil)
                exportMenu(item)
                    .disabled(actionsUnavailable(for: item))
                IconButton("xmark", label: strings(.actionClose)) { model.selectedRecordingID = nil }
            }
            HStack {
                PlaybackButton(source: model.playback.source, preparing: model.playback.preparing) {
                    model.play(item, side: $0.side)
                }
                .disabled(item.manifest.status == .recording || item.manifest.status == .finalizing)
                Spacer()
                Menu {
                    Button(strings(.libraryRename)) { model.rename(item) }
                        .disabled(!model.canEdit(item))
                    Button(strings(.libraryReveal)) {
                        NSWorkspace.shared.activateFileViewerSelecting([item.directory])
                    }
                    Button(strings(.libraryTrash), role: .destructive) { model.trash(item) }
                        .disabled(!model.canEdit(item))
                } label: {
                    ControlIcon(systemName: "ellipsis").hoverBackground()
                }.menuStyle(.borderlessButton).menuIndicator(.hidden)
                    .fixedSize().accessibilityLabel(strings(.actionMore)).help(strings(.actionMore))
            }.simultaneousGesture(TapGesture().onEnded { findController.focusLibrary() })
                .disabled(actionsUnavailable(for: item))
            SavedTranscriptView(
                item: item,
                seek: { seconds in
                    if model.playback.duration > 0 {
                        model.playback.seek(seconds)
                    } else {
                        model.play(item, side: model.playback.source.side, at: seconds)
                    }
                }, processing: model.storedProcessing,
                canProcess: !model.preview && !model.session.active && !model.starting && !model.endingSession
                    && model.libraryMutationTask == nil,
                continueProcessing: model.continueProcessing
            )
            if model.canRecover(item) {
                HStack {
                    Text(
                        item.manifest.failureCode.flatMap(MediaFailure.init(rawValue:)).map {
                            strings.error($0)
                        } ?? item.manifest.failure ?? strings(.libraryOriginalsSaved)
                    ).font(typography.caption)
                        .foregroundStyle(.orange)
                    Spacer()
                    Button(strings(.libraryRecover)) { model.recover(item) }.disabled(
                        !model.canStartRecovery(item))
                }
            }
            if model.playback.duration > 0 {
                if !model.playback.waveform.isEmpty {
                    RecordingWaveform(
                        samples: model.playback.waveform,
                        progress: model.playback.position / model.playback.duration
                    ) {
                        model.playback.seek($0 * model.playback.duration)
                    }
                }
                HStack {
                    Button {
                        model.playback.toggle()
                    } label: {
                        Image(systemName: model.playback.playing ? "pause.fill" : "play.fill")
                    }
                    Text(durationText(model.playback.position)).font(typography.caption.monospacedDigit())
                    Slider(
                        value: Binding(get: { model.playback.position }, set: { model.playback.seek($0) }),
                        in: 0...max(1, model.playback.duration)
                    )
                    .accessibilityLabel(strings(.librarySeek))
                    Text(durationText(model.playback.duration)).font(typography.caption.monospacedDigit())
                }
            }
        }
    }
}

private struct LibraryRecordingRow<Accessory: View>: View {
    @Environment(\.appTypography) private var typography
    @Environment(\.appStrings) private var strings
    let title: String
    let date: Date
    let duration: TimeInterval
    let systemImage: String
    let saved: Bool
    let selected: Bool
    let showsSeparator: Bool
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(
                    selected ? AnyShapeStyle(.primary) : AnyShapeStyle(saved ? Color.accentColor : .secondary)
                )
                .frame(width: 18, height: typography.controlSide).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 4) {
                    Text(title).font(typography.row).lineLimit(2).help(title)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
                    accessory
                }
                HStack(alignment: .firstTextBaseline) {
                    Text(
                        date.formatted(
                            Date.FormatStyle(date: .numeric, time: .omitted).locale(strings.locale)))
                    Spacer(minLength: 8)
                    Text(durationText(duration)).monospacedDigit().fixedSize()
                }.font(typography.caption).foregroundStyle(.secondary)
                    // Keep metadata at the content edge while the full-size accessory moves outward.
                    .padding(.trailing, 10)
            }
        }.padding(.vertical, 10).contentShape(Rectangle())
            .accessibilityElement(children: .contain).accessibilityLabel(title)
            .overlay(alignment: .bottom) {
                if showsSeparator { Divider().padding(.leading, 28).padding(.trailing, 10) }
            }
    }
}
