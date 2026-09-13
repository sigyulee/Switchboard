import AppKit
import BridgeCore
import RecorderKit
import SwiftUI

struct LibraryView: View {
    @Environment(\.appStrings) private var strings
    @Bindable var model: AppModel
    @ViewState private var query = ""
    @FocusState private var searchFocused: Bool
    private var items: [RecordingItem] {
        query.isEmpty
            ? model.recordings
            : model.recordings.filter { $0.manifest.title.localizedCaseInsensitiveContains(query) }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(strings(.navigationRecordings)).font(.system(size: 20, weight: .semibold))
                Text("\(model.recordings.count)").foregroundStyle(.secondary)
                Spacer()
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 14)).foregroundStyle(.secondary).accessibilityHidden(true)
                    TextField(strings(.librarySearch), text: $query)
                        .textFieldStyle(.plain).font(.system(size: 15))
                        .focused($searchFocused)
                        .accessibilityLabel(strings(.librarySearch))
                }
                .padding(.horizontal, 10).frame(width: 230, height: 34)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8).strokeBorder(
                        searchFocused ? Color.accentColor : Color.primary.opacity(0.12),
                        lineWidth: searchFocused ? 2 : 1)
                }
            }.padding(.horizontal, 24).padding(.vertical, 16)
            if items.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "waveform").font(.system(size: 40, weight: .light)).foregroundStyle(
                        .secondary)
                    Text(query.isEmpty ? strings(.libraryEmpty) : strings(.libraryNoResults)).font(.headline)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $model.selectedRecordingID) {
                    ForEach(items) { item in
                        HStack(spacing: 12) {
                            Image(
                                systemName: item.manifest.status == .complete
                                    ? "waveform" : "clock.arrow.circlepath"
                            )
                            .foregroundStyle(.blue).frame(width: 24)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.manifest.title).font(.system(size: 15, weight: .medium)).lineLimit(
                                    1)
                            }
                            Spacer()
                            Text(durationText(item.manifest.duration)).font(
                                .system(size: 14).monospacedDigit()
                            ).foregroundStyle(.secondary)
                            if !item.manifest.gaps.isEmpty {
                                Image(systemName: "info.circle").help(strings(.libraryGaps))
                            }
                        }.padding(.vertical, 7).tag(item.id)
                    }
                }.listStyle(.inset)
                if let item = model.selectedItem {
                    Divider()
                    detail(item).padding(16)
                }
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

    @ViewBuilder private func detail(_ item: RecordingItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button {
                    model.play(item)
                } label: {
                    Label(
                        model.playback.preparing ? strings(.libraryPreparing) : strings(.libraryPlay),
                        systemImage: "play.fill")
                }
                .disabled(item.manifest.status == .recording || item.manifest.status == .finalizing)
                Menu(strings(.librarySources)) {
                    Button(strings(.libraryPlayCaller)) { model.play(item, side: .caller) }
                    Button(strings(.libraryPlayAgent)) { model.play(item, side: .chrome) }
                }
                Menu(strings(.actionExport)) {
                    Button(strings(.libraryExportAll)) { model.exportAll(item) }
                    Divider()
                    Button(strings(.libraryExportMix)) { model.export(item) }
                    Button(strings(.libraryExportCaller)) { model.export(item, side: .caller) }
                    Button(strings(.libraryExportAgent)) { model.export(item, side: .chrome) }
                }
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
                    Image(systemName: "ellipsis")
                }.menuStyle(.borderlessButton).frame(width: 25)
            }.disabled(
                model.exportBusy || model.playback.preparing || model.preview
                    || item.directory == model.recordingURL)
            if model.canRecover(item) {
                HStack {
                    Text(
                        item.manifest.failureCode.flatMap(MediaFailure.init(rawValue:)).map {
                            strings.error($0)
                        } ?? item.manifest.failure ?? strings(.libraryOriginalsSaved)
                    ).font(.system(size: 14))
                        .foregroundStyle(.orange)
                    Spacer()
                    Button(strings(.libraryRecover)) { model.recover(item) }.disabled(
                        !model.canEdit(item))
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
                    Text(durationText(model.playback.position)).font(.system(size: 14).monospacedDigit())
                    Slider(
                        value: Binding(get: { model.playback.position }, set: { model.playback.seek($0) }),
                        in: 0...max(1, model.playback.duration)
                    )
                    .accessibilityLabel(strings(.librarySeek))
                    Text(durationText(model.playback.duration)).font(.system(size: 14).monospacedDigit())
                }
            }
        }
    }
}
