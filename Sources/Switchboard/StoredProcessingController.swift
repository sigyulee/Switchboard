import BridgeCore
import Foundation
import Observation
import RecorderKit
import TranscriptKit

@MainActor @Observable final class StoredProcessingController {
    private let processor = StoredTranscriptProcessor()
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private(set) var itemID: UUID?
    private(set) var busy = false
    private(set) var entries: [TranscriptEntry] = []
    private(set) var revision = 0
    var error: Error?
    var requiredModels: TranscriptConfiguration?

    func start(_ item: RecordingItem) {
        guard !busy else { return }
        busy = true
        itemID = item.id
        entries = []
        let id = UUID()
        generation = id
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                if generation == id {
                    busy = false
                    task = nil
                    revision += 1
                }
            }
            do {
                let metadata = try await Task.detached(priority: .utility) {
                    let session: SessionManifest?
                    if item.directory.pathExtension.lowercased() == SessionManifest.packageExtension
                        || FileManager.default.fileExists(
                            atPath: item.directory.appendingPathComponent(SessionManifest.filename).path)
                    {
                        session = try SessionStore.metadata(in: item.directory)
                    } else {
                        session = nil
                    }
                    let journal = try TranscriptJournal(sessionID: item.id, directory: item.directory)
                    return (session, await journal.snapshot())
                }.value
                guard !Task.isCancelled, generation == id else { return }
                entries = metadata.1
                let result = try await processor.process(item: item, session: metadata.0) {
                    [weak self] event in
                    await self?.receive(event, generation: id)
                }
                if generation == id,
                    result.states.values.contains(where: {
                        $0.speech == .downloadRequired || $0.translation == .downloadRequired
                    })
                {
                    requiredModels = result.progress.configuration
                } else if generation == id, !result.sourceFailures.isEmpty {
                    error = AppFailure.detail(result.sourceFailures.values.sorted().joined(separator: "\n"))
                } else if generation == id, result.disposition == .incomplete {
                    let messages = result.states.values.compactMap(\.message).filter { !$0.isEmpty }
                    error =
                        messages.isEmpty
                        ? TranscriptFailure.unavailableFormat
                        : AppFailure.detail(messages.joined(separator: "\n"))
                }
            } catch is CancellationError {
            } catch { if generation == id { self.error = error } }
        }
    }

    func pause() async {
        let pending = task
        pending?.cancel()
        await processor.pause()
        await pending?.value
        busy = false
    }

    private func receive(_ event: TranscriptEvent, generation: UUID) {
        guard self.generation == generation else { return }
        switch event {
        case .partial(let entry), .final(let entry), .upsert(let entry):
            if let index = entries.firstIndex(where: { $0.id == entry.id }) {
                entries[index] = entry
            } else {
                entries.append(entry)
            }
        case .state, .gap: break
        }
    }
}
