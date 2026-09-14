import BridgeCore
import RecorderKit
import SwiftUI
import TranscriptKit

struct SavedTranscriptView: View {
    @Environment(\.appTypography) private var typography
    @Environment(\.appStrings) private var strings
    @Environment(AppFindController.self) private var findController
    let item: RecordingItem
    let seek: (Double) -> Void
    @Bindable var processing: StoredProcessingController
    let canProcess: Bool
    let continueProcessing: (RecordingItem) -> Void
    @ViewState private var canResume = false
    @ViewState private var entries: [TranscriptEntry] = []
    @ViewState private var description = ""
    @ViewState private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !description.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(strings(.sessionDescriptionLabel)).foregroundStyle(.secondary)
                    Text(description).textSelection(.enabled)
                }.font(typography.caption).fixedSize(horizontal: false, vertical: true)
            }
            if canResume {
                Button(
                    strings(
                        processing.busy && processing.itemID == item.id
                            ? .actionPause : .libraryContinueTranscription)
                ) {
                    if processing.busy { Task { await processing.pause() } } else { continueProcessing(item) }
                }.disabled(!canProcess || (processing.busy && processing.itemID != item.id))
            }
            if !entries.isEmpty || (processing.itemID == item.id && !processing.entries.isEmpty) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(strings(.libraryTranscript)).font(typography.section)
                        Spacer()
                        IconButton("magnifyingglass", label: strings(.transcriptSearch)) {
                            findController.findTranscript(owner: item.id)
                        }
                    }
                    TranscriptMessages(
                        transcriptID: item.id,
                        entries: processing.itemID == item.id && processing.busy
                            ? processing.entries : entries, seek: seek,
                        isProcessing: processing.itemID == item.id && processing.busy
                    ).id(item.id).frame(minHeight: 120, maxHeight: .infinity)
                }
            }
            if let error { Text(error).font(typography.caption).foregroundStyle(.orange) }
            if entries.isEmpty && !canResume && error == nil {
                Text(strings(.libraryNoTranscript)).font(typography.body).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: "\(item.id)-\(processing.revision)") {
            entries = []
            description = ""
            error = nil
            canResume = false
            do {
                let item = item
                let result = try await Task.detached(priority: .utility) {
                    let journal = try TranscriptJournal(sessionID: item.id, directory: item.directory)
                    let session: SessionManifest?
                    if item.directory.pathExtension.lowercased() == SessionManifest.packageExtension
                        || FileManager.default.fileExists(
                            atPath: item.directory.appendingPathComponent(SessionManifest.filename).path)
                    {
                        session = try SessionStore.metadata(in: item.directory)
                    } else {
                        session = nil
                    }
                    let progress = try await StoredTranscriptProcessor.progress(item: item, session: session)
                    return (
                        await journal.snapshot(), session?.description ?? "",
                        progress.hasWork && !progress.needsConfiguration
                    )
                }.value
                guard !Task.isCancelled else { return }
                entries = result.0
                description = result.1
                canResume = result.2
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }
}
