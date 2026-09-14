import AVFoundation
import Foundation
import Observation
import Synchronization

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

private func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw CheckFailure(description: message) }
}

private final class PermissionChanges: Sendable {
    private let storage = Mutex(0)
    var count: Int { storage.withLock { $0 } }
    func record() { storage.withLock { $0 += 1 } }
}

@MainActor private final class PermissionSystem {
    var status: AVAuthorizationStatus = .notDetermined
    var reads = 0
    var requests = 0
    var completionWasCancelled = false
    private var continuation: CheckedContinuation<Bool, Never>?

    func read() -> AVAuthorizationStatus {
        reads += 1
        return status
    }

    func request() async -> Bool {
        requests += 1
        let granted = await withCheckedContinuation { continuation = $0 }
        completionWasCancelled = Task.isCancelled
        return granted
    }

    func complete(_ status: AVAuthorizationStatus) {
        self.status = status
        continuation?.resume(returning: status == .authorized)
        continuation = nil
    }

    func makeAccess(preview: Bool = false) -> MicrophoneAccess {
        MicrophoneAccess(preview: preview, readStatus: read, requestAccess: request)
    }
}

@main private struct MicrophoneAccessChecks {
    @MainActor static func main() async {
        do {
            try await grantInvalidatesPermissionObservation()
            try await deniedRequestStaysDisallowed()
            try deniedAndRestrictedDoNotRequestAgain()
            try refreshObservesExternalGrantAndRevocation()
            try await duplicateRequestsShareOnePrompt()
            try previewDoesNotConsultTheSystem()
            try await releasingAccessCancelsPendingWork()
            print("Microphone access checks passed: 7 checks; no system permission requests.")
        } catch {
            FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
            exit(1)
        }
    }

    @MainActor static func waitFor(_ condition: () -> Bool, _ message: String) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition() {
            if ContinuousClock.now >= deadline { throw CheckFailure(description: message) }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    @MainActor static func observeAllowed(_ access: MicrophoneAccess, changes: PermissionChanges) {
        withObservationTracking {
            _ = access.allowed
        } onChange: {
            MainActor.assertIsolated()
            changes.record()
        }
    }

    @MainActor static func grantInvalidatesPermissionObservation() async throws {
        let system = PermissionSystem()
        let access = system.makeAccess()
        let changes = PermissionChanges()
        try require(!access.allowed, "Undetermined microphone access must not allow capture")
        observeAllowed(access, changes: changes)
        access.request()
        try await waitFor({ system.requests == 1 }, "Microphone request did not start")
        try require(access.isRequesting, "Pending request must disable another request")
        try require(changes.count == 0, "A pending request must not grant microphone access")
        system.complete(.authorized)
        try await waitFor({ !access.isRequesting }, "Microphone request did not finish")
        try require(access.allowed, "System grant must allow microphone capture")
        try require(
            changes.count == 1,
            "System grant must invalidate permission observation without an unrelated state change")
    }

    @MainActor static func deniedRequestStaysDisallowed() async throws {
        let system = PermissionSystem()
        let access = system.makeAccess()
        access.request()
        try await waitFor({ system.requests == 1 }, "Microphone request did not start")
        system.complete(.denied)
        try await waitFor({ !access.isRequesting }, "Denied request did not finish")
        try require(!access.allowed && access.status == .denied, "System denial must remain disallowed")
        access.request()
        try require(!access.isRequesting, "A denied request must require a system settings change")
    }

    @MainActor static func deniedAndRestrictedDoNotRequestAgain() throws {
        for status: AVAuthorizationStatus in [.denied, .restricted] {
            let system = PermissionSystem()
            system.status = status
            let access = system.makeAccess()
            try require(!access.allowed, "Denied and restricted microphone access must not allow capture")
            access.request()
            try require(!access.isRequesting, "Determined permissions must not start another request")
        }
    }

    @MainActor static func refreshObservesExternalGrantAndRevocation() throws {
        let system = PermissionSystem()
        system.status = .denied
        let access = system.makeAccess()
        let changes = PermissionChanges()
        observeAllowed(access, changes: changes)
        system.status = .authorized
        access.refresh()
        try require(access.allowed, "Refresh must recognize an external system grant")
        try require(changes.count == 1, "External grant must invalidate permission observation")
        observeAllowed(access, changes: changes)
        system.status = .denied
        access.refresh()
        try require(!access.allowed, "Refresh must recognize revoked microphone access")
        try require(changes.count == 2, "Revocation must invalidate permission observation")
        system.status = .restricted
        access.refresh()
        try require(!access.allowed, "A system restriction must remain disallowed")
    }

    @MainActor static func duplicateRequestsShareOnePrompt() async throws {
        let system = PermissionSystem()
        let access = system.makeAccess()
        access.request()
        access.request()
        try await waitFor({ system.requests == 1 }, "Concurrent requests did not share one prompt")
        access.request()
        system.complete(.authorized)
        try await waitFor({ !access.isRequesting }, "Shared microphone request did not finish")
        try require(system.requests == 1, "Duplicate requests must not issue another system prompt")
        access.request()
        try require(!access.isRequesting, "Authorized microphone access must not request again")
    }

    @MainActor static func previewDoesNotConsultTheSystem() throws {
        let system = PermissionSystem()
        system.status = .denied
        let access = system.makeAccess(preview: true)
        access.refresh()
        access.request()
        try require(access.allowed && !access.isRequesting, "Preview microphone access must stay allowed")
        try require(system.reads == 0 && system.requests == 0, "Preview must not consult system permission")
    }

    @MainActor static func releasingAccessCancelsPendingWork() async throws {
        let system = PermissionSystem()
        var access: MicrophoneAccess? = system.makeAccess()
        let released = { [weak access] in access == nil }
        access?.request()
        try await waitFor({ system.requests == 1 }, "Microphone request did not start")
        access = nil
        try require(released(), "Pending permission work must not retain its owner")
        system.complete(.authorized)
        try await waitFor({ system.completionWasCancelled }, "Releasing access must cancel pending work")
    }
}
