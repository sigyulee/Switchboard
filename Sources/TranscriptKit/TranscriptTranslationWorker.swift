import BridgeCore
import Foundation
@preconcurrency import Translation

@available(macOS 26.0, *)
actor TranscriptTranslationWorker {
    struct Request: Sendable {
        let entry: TranscriptEntry
    }
    private let source: String
    private let target: String
    private let queue: AsyncStream<Request>
    private let continuation: AsyncStream<Request>.Continuation
    private let completion: @Sendable (TranscriptEntry, String?, TranscriptTranslationStatus) async -> Void
    private var session: TranslationSession?
    private var task: Task<Void, Never>?
    private var closed = false

    init(
        source: String, target: String,
        completion: @escaping @Sendable (TranscriptEntry, String?, TranscriptTranslationStatus) async -> Void
    ) {
        self.source = source
        self.target = target
        self.completion = completion
        (queue, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingOldest(32))
    }

    func start() {
        guard task == nil, !closed else { return }
        task = Task { await self.consume() }
    }

    func enqueue(_ entry: TranscriptEntry) -> Bool {
        guard !closed else { return false }
        switch continuation.yield(Request(entry: entry)) {
        case .enqueued: return true
        default: return false
        }
    }

    func finish() async {
        closed = true
        continuation.finish()
        await task?.value
        task = nil
        session = nil
    }

    func cancel() async {
        closed = true
        continuation.finish()
        task?.cancel()
        session?.cancel()
        await task?.value
        task = nil
        session = nil
    }

    private func consume() async {
        let availability = LanguageAvailability()
        let source = Locale.Language(identifier: source)
        let target = Locale.Language(identifier: target)
        for await request in queue {
            guard !Task.isCancelled else { break }
            let status = await availability.status(from: source, to: target)
            guard !Task.isCancelled else { break }
            guard status == .installed else {
                await completion(request.entry, nil, status == .supported ? .downloadRequired : .unsupported)
                continue
            }
            if session == nil { session = TranslationSession(installedSource: source, target: target) }
            do {
                guard let session else { continue }
                let response = try await session.translate(request.entry.original)
                guard !Task.isCancelled else { break }
                await completion(request.entry, response.targetText, .translated)
            } catch {
                guard !Task.isCancelled else { break }
                await completion(request.entry, nil, .failed)
            }
        }
    }
}
