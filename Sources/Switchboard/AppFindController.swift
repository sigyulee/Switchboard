// SPDX-License-Identifier: AGPL-3.0-only
import Observation
import SwiftUI

@MainActor @Observable final class AppFindController {
    struct Request: Equatable {
        let owner: UUID
        let generation = UUID()
    }

    private(set) var transcriptOwner: UUID?
    private(set) var request: Request?

    func focusTranscript(owner: UUID) { transcriptOwner = owner }

    func focusLibrary() { transcriptOwner = nil }

    func releaseTranscript(owner: UUID) {
        if transcriptOwner == owner { transcriptOwner = nil }
        if request?.owner == owner { request = nil }
    }

    func findTranscript(owner: UUID) {
        focusTranscript(owner: owner)
        request = Request(owner: owner)
    }

    @discardableResult func requestTranscriptFind() -> Bool {
        guard let transcriptOwner else { return false }
        findTranscript(owner: transcriptOwner)
        return true
    }
}

private struct AppFindControllerKey: FocusedValueKey {
    typealias Value = AppFindController
}

extension FocusedValues {
    var appFindController: AppFindController? {
        get { self[AppFindControllerKey.self] }
        set { self[AppFindControllerKey.self] = newValue }
    }
}
