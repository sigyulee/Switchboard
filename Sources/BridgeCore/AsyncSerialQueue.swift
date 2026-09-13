import Foundation
import Synchronization

/// Executes synchronous work serially without blocking the caller's executor.
public final class AsyncSerialQueue: Sendable {
    public let dispatchQueue: DispatchQueue

    public init(label: String, qos: DispatchQoS = .default) {
        dispatchQueue = DispatchQueue(label: label, qos: qos)
    }

    public func submit(_ operation: @escaping @Sendable () -> Void) {
        dispatchQueue.async(execute: operation)
    }

    /// Once accepted, lifecycle work completes even if its caller is cancelled.
    public func complete<Value: Sendable>(
        isolation: isolated (any Actor)? = #isolation,
        _ operation: @escaping @Sendable () -> Value
    ) async -> Value {
        await withCheckedContinuation { continuation in
            dispatchQueue.async { continuation.resume(returning: operation()) }
        }
    }

    /// Cancellation skips queued work; an operation already running is allowed to finish.
    public func run<Value: Sendable>(
        isolation: isolated (any Actor)? = #isolation,
        _ operation: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        let cancellation = Cancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                dispatchQueue.async {
                    do {
                        if cancellation.requested.withLock({ $0 }) { throw CancellationError() }
                        continuation.resume(returning: try operation())
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            cancellation.requested.withLock { $0 = true }
        }
    }
}

private final class Cancellation: Sendable {
    let requested = Mutex(false)
}
