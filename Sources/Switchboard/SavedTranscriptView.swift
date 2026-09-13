import BridgeCore
import RecorderKit
import SwiftUI
import TranscriptKit

struct SavedTranscriptView: View {
    @Environment(\.appStrings) private var strings
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
                Text(description).font(.system(size: 14)).foregroundStyle(.secondary).textSelection(.enabled)
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
                DisclosureGroup(strings(.libraryTranscript)) {
                    TranscriptMessages(
                        entries: processing.itemID == item.id && processing.busy
                            ? processing.entries : entries, seek: seek
                    ).frame(minHeight: 180, maxHeight: 300)
                }
            }
            if let error { Text(error).font(.system(size: 14)).foregroundStyle(.orange) }
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
