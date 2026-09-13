import BridgeCore
import Foundation
import Synchronization

struct AsyncSerialQueueChecks {
    @MainActor
    func workDoesNotBlockMainActor() async throws {
        let queue = AsyncSerialQueue(label: "queue-check.main-progress")
        let progress = DispatchSemaphore(value: 0)
        let result = try await queue.run {
            Task { @MainActor in progress.signal() }
            return progress.wait(timeout: .now() + 5) == .success
        }
        try expect(result)
    }

    @MainActor
    func cancelledQueuedWorkDoesNotExecute() async throws {
        let queue = AsyncSerialQueue(label: "queue-check.cancellation")
        let release = DispatchSemaphore(value: 0)
        let started = AsyncStream<Void>.makeStream()
        let count = Counter()
        let first = Task {
            try await queue.run {
                started.continuation.yield(())
                return release.wait(timeout: .now() + 5) == .success
            }
        }
        for await _ in started.stream { break }
        let cancelled = Task { try await queue.run { count.increment() } }
        await Task.yield()
        cancelled.cancel()
        release.signal()
        let released = try await first.value
        try expect(released)
        do {
            _ = try await cancelled.value
            throw CheckFailure(description: "cancelled work completed")
        } catch is CancellationError {}
        try expect(count.value == 0)
        started.continuation.finish()
    }

    func valuesAndErrorsReturnToCaller() async throws {
        let queue = AsyncSerialQueue(label: "queue-check.results")
        let value = try await queue.run { 42 }
        try expect(value == 42)
        do {
            _ = try await queue.run { () throws -> Int in throw FixtureError.expected }
            throw CheckFailure(description: "queued error was lost")
        } catch FixtureError.expected {}
    }

    @MainActor
    func lifecycleWorkCompletesAfterCancellation() async throws {
        let queue = AsyncSerialQueue(label: "queue-check.lifecycle")
        let count = Counter()
        queue.submit { count.increment() }
        let task = Task {
            await queue.complete {
                count.increment()
                return count.value
            }
        }
        task.cancel()
        let value = await task.value
        try expect(value == 2)
    }
}

private enum FixtureError: Error { case expected }

private final class Counter: Sendable {
    private let storage = Mutex(0)
    var value: Int { storage.withLock { $0 } }
    func increment() { storage.withLock { $0 += 1 } }
}
