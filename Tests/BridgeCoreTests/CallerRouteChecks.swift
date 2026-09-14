import BridgeCore
import Foundation

struct CallerRouteChecks {
    func armingRequiresBothAssociatedActiveDirections() throws {
        var state = CallerRouteState()
        let epoch = state.reset(sessionID: UUID(), callerID: "example.caller")
        try expect(state.observe(evidence(speaker: true, microphone: false), at: 0, epoch: epoch) == .waiting)
        try expect(!state.isArmed)
        try expect(state.observe(evidence(speaker: false, microphone: true), at: 3, epoch: epoch) == .waiting)
        try expect(state.observe(evidence(output: false), at: 4, epoch: epoch) == .waiting)
        try expect(state.observe(evidence(input: false), at: 5, epoch: epoch) == .waiting)
        try expect(!state.isArmed)
        try expect(state.observe(evidence(), at: 6, epoch: epoch) == .connected)
        try expect(state.isArmed)
    }

    func inactiveStreamsAndElapsedSilenceDoNotDisconnect() throws {
        var state = CallerRouteState()
        let epoch = state.reset(sessionID: UUID(), callerID: "example.caller")
        _ = state.observe(evidence(), at: 0, epoch: epoch)
        // Neither amplitude nor monitor state is part of the evidence type.
        // An idle graph retaining both device associations remains connected.
        for time in [1.0, 30.0, 600.0] {
            try expect(
                state.observe(evidence(output: false, input: false), at: time, epoch: epoch) == .connected)
            try expect(state.isArmed)
        }
    }

    func actualMembershipLossMustRemainObservedThroughDebounce() throws {
        var state = CallerRouteState()
        let epoch = state.reset(sessionID: UUID(), callerID: "example.caller")
        _ = state.observe(evidence(), at: 0, epoch: epoch)
        let missingSpeaker = evidence(speaker: false)
        try expect(state.observe(missingSpeaker, at: 1, epoch: epoch) == .waiting)
        try expect(state.observe(missingSpeaker, at: 2.99, epoch: epoch) == .waiting)
        try expect(state.observe(evidence(), at: 3, epoch: epoch) == .connected)
        try expect(state.observe(missingSpeaker, at: 4, epoch: epoch) == .waiting)
        try expect(state.observe(missingSpeaker, at: 5.99, epoch: epoch) == .waiting)
        try expect(state.observe(missingSpeaker, at: 6, epoch: epoch) == .disconnected)
        try expect(state.observe(evidence(), at: 7, epoch: epoch) == .disconnected)
        try expect(state.observe(.unknown(.queryFailed(-1)), at: 8, epoch: epoch) == .disconnected)
    }

    func unknownEvidenceInterruptsLossDebounce() throws {
        var state = CallerRouteState()
        let epoch = state.reset(sessionID: UUID(), callerID: "example.caller")
        _ = state.observe(evidence(), at: 0, epoch: epoch)
        let lost = evidence(microphone: false)
        _ = state.observe(lost, at: 1, epoch: epoch)
        try expect(state.observe(.unknown(.queryFailed(-1)), at: 2, epoch: epoch) == .unknown)
        try expect(state.evidence.issue == .queryFailed(-1))
        try expect(state.isArmed)
        try expect(state.observe(lost, at: 3, epoch: epoch) == .waiting)
        try expect(state.observe(lost, at: 4.99, epoch: epoch) == .waiting)
        try expect(state.observe(lost, at: 5, epoch: epoch) == .disconnected)
    }

    func verifiedProcessDisappearanceRequiresPriorArming() throws {
        var state = CallerRouteState()
        let epoch = state.reset(sessionID: UUID(), callerID: "example.caller")
        let absent = CallerRouteEvidence(
            verifiedProcessCount: 0, speakerAssociated: false, microphoneAssociated: false,
            isRunningOutput: false, isRunningInput: false)
        try expect(state.observe(absent, at: 0, epoch: epoch) == .waiting)
        try expect(state.observe(absent, at: 10, epoch: epoch) == .waiting)
        _ = state.observe(evidence(), at: 11, epoch: epoch)
        try expect(state.observe(absent, at: 12, epoch: epoch) == .waiting)
        try expect(state.observe(absent, at: 14, epoch: epoch) == .disconnected)
    }

    func profileSessionAndExplicitResumeResetRejectStaleSamples() throws {
        var state = CallerRouteState()
        let session = UUID()
        let first = state.reset(sessionID: session, callerID: "example.first")
        _ = state.observe(evidence(), at: 0, epoch: first)
        _ = state.observe(evidence(speaker: false), at: 1, epoch: first)
        _ = state.observe(evidence(speaker: false), at: 3, epoch: first)
        try expect(state.status == .disconnected)
        let resumed = state.reset(sessionID: session, callerID: "example.first")
        try expect(resumed != first && !state.isArmed && state.status == .waiting)
        try expect(state.observe(evidence(), at: 4, epoch: first) == .waiting)
        try expect(!state.isArmed)
        try expect(state.observe(evidence(output: false), at: 5, epoch: resumed) == .waiting)
        try expect(state.observe(evidence(), at: 6, epoch: resumed) == .connected)
        let changedCaller = state.reset(sessionID: session, callerID: "example.second")
        try expect(state.callerID == "example.second" && !state.isArmed)
        try expect(state.observe(evidence(), at: 7, epoch: resumed) == .waiting)
        _ = state.observe(evidence(), at: 8, epoch: changedCaller)
        let newSession = UUID()
        _ = state.reset(sessionID: newSession, callerID: "example.second")
        try expect(state.sessionID == newSession && state.status == .waiting && !state.isArmed)
    }

    func invalidClocksAndIncompleteEvidenceCannotDisconnect() throws {
        var state = CallerRouteState()
        let epoch = state.reset(sessionID: UUID(), callerID: "example.caller")
        _ = state.observe(evidence(), at: 10, epoch: epoch)
        let lost = evidence(speaker: false)
        _ = state.observe(lost, at: 11, epoch: epoch)
        for time in [Double.nan, .infinity, -.infinity, -1, 9] {
            try expect(state.observe(lost, at: time, epoch: epoch) == .unknown)
            try expect(state.evidence.issue == .invalidClock)
        }
        try expect(state.observe(lost, at: 20, epoch: epoch) == .waiting)
        let incomplete = CallerRouteEvidence(
            verifiedProcessCount: 1, speakerAssociated: false, microphoneAssociated: true,
            isRunningOutput: nil, isRunningInput: true)
        try expect(state.observe(incomplete, at: 21, epoch: epoch) == .unknown)
        try expect(state.observe(lost, at: 22, epoch: epoch) == .waiting)
        try expect(state.observe(lost, at: 23, epoch: epoch) == .waiting)
        try expect(state.observe(evidence(), at: 24, epoch: epoch) == .connected)
        let inconsistent = CallerRouteEvidence(
            verifiedProcessCount: 0, speakerAssociated: true, microphoneAssociated: true,
            isRunningOutput: true, isRunningInput: true)
        try expect(state.observe(inconsistent, at: 25, epoch: epoch) == .unknown)
    }

    private func evidence(
        speaker: Bool = true, microphone: Bool = true, output: Bool = true, input: Bool = true
    ) -> CallerRouteEvidence {
        CallerRouteEvidence(
            verifiedProcessCount: 1, speakerAssociated: speaker, microphoneAssociated: microphone,
            isRunningOutput: output, isRunningInput: input)
    }
}
