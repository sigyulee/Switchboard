// SPDX-License-Identifier: AGPL-3.0-only
import BridgeCore
import Darwin
import Foundation
import Synchronization

private struct SearchCheckFailure: Error, CustomStringConvertible {
    let description: String
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw SearchCheckFailure(description: message) }
}

@main @MainActor struct SearchChecks {
    static func main() {
        let checks: [(String, () throws -> Void)] = [
            ("Korean original and translation occurrences remain ordered", koreanOccurrences),
            ("English matching ignores case and accents while preserving Unicode offsets", unicodeRanges),
            ("empty, whitespace and absent queries have no matches", emptyQueries),
            ("forward and backward navigation wrap across every occurrence", navigation),
            ("old matches expand the visible transcript suffix", olderMessages),
            ("cancelled matching discards partial results", cancellation),
            ("contextual find switches panes and releases stale owners", contextualFind),
            ("content growth preserves following while user review pauses it", scrollFollowing),
        ]
        var failures = 0
        for (name, check) in checks {
            do {
                try check()
                print("PASS \(name)")
            } catch {
                failures += 1
                print("FAIL \(name): \(error)")
            }
        }
        if failures > 0 { exit(1) }
        print("\(checks.count) transcript search checks passed.")
    }

    private static func scrollFollowing() throws {
        var state = TranscriptScrollFollow()
        state.userScrollEnded(atBottom: false)
        try require(state.shouldFollow(searchVisible: false), "Content growth detached the latest message")
        try require(!state.shouldFollow(searchVisible: true), "Search must not be interrupted by new text")
        state.userScrollBegan()
        try require(!state.shouldFollow(searchVisible: false), "A user gesture was overridden")
        state.userScrollMoved(from: 100, to: 150, atBottom: true)
        state.userScrollEnded(atBottom: false)
        try require(
            state.shouldFollow(searchVisible: false), "Growth during downward scrolling disabled follow")
        state.userScrollBegan()
        state.userScrollMoved(from: 150, to: 80, atBottom: false)
        state.userScrollEnded(atBottom: false)
        try require(!state.shouldFollow(searchVisible: false), "Reviewing earlier text resumed following")
        state.userScrollBegan()
        state.userScrollMoved(from: 80, to: 200, atBottom: true)
        state.userScrollEnded(atBottom: false)
        try require(
            state.shouldFollow(searchVisible: false), "Reaching the bottom before new text did not resume")
        state.userScrollBegan()
        try require(!state.shouldFollow(searchVisible: true), "Search did not pause follow")
        state.userScrollEnded(atBottom: false)
        try require(
            !state.userIsScrolling && state.shouldFollow(searchVisible: false),
            "Search retained a completed gesture")
        state.userScrollBegan()
        state.userScrollMoved(from: 200, to: 185, atBottom: true)
        state.userScrollEnded(atBottom: false)
        try require(!state.shouldFollow(searchVisible: false), "Upward momentum snapped back to latest")
        state.showEarlier()
        try require(!state.shouldFollow(searchVisible: false), "Loading older messages kept following")
        state.resume()
        state.userScrollEnded(atBottom: false)
        try require(state.shouldFollow(searchVisible: false), "The latest button did not restore following")
    }

    private static func koreanOccurrences() throws {
        let first = entry("안녕하세요. 안녕!", translation: "안녕이라는 인사입니다.")
        let second = entry("다음 내용", translation: "안녕")
        let matches = TranscriptSearch.matches(in: [first, second], query: "안녕")
        try require(matches.count == 4, "each original and translated occurrence must be counted")
        try require(matches.map(\.entryID) == [first.id, first.id, first.id, second.id], "entry order")
        try require(
            matches.map(\.field) == [.original, .original, .translation, .translation], "field order")
        try require(matches[0].range.location == 0 && matches[1].range.location == 7, "Korean offsets")
        try require(
            TranscriptSearch.matches(in: [entry("안녕하세요")], query: "안녕").count == 1,
            "canonically equivalent Korean must match")
    }

    private static func unicodeRanges() throws {
        let sample = entry("👋 CAFÉ, cafe\u{301}, Café", translation: "cafe")
        let matches = TranscriptSearch.matches(in: [sample], query: "cAfE")
        try require(matches.count == 4, "case and diacritic variants must match")
        let expected = ["CAFÉ", "cafe\u{301}", "Café", "cafe"]
        for (match, text) in zip(matches, expected) {
            let source = match.field == .original ? sample.original : sample.translation!
            guard let range = Range(match.range, in: source) else {
                throw SearchCheckFailure(description: "match has an invalid Unicode range")
            }
            try require(String(source[range]) == text, "range must refer to original, unnormalized text")
        }
        try require(matches[0].range.location == 3, "offset must account for emoji's UTF-16 length")
        try require(TranscriptSearch.matches(in: [entry("aaaa")], query: "aa").count == 2, "nonoverlap")
    }

    private static func emptyQueries() throws {
        for query in ["", " \n\t", "absent"] {
            try require(TranscriptSearch.matches(in: [entry("Visible text")], query: query).isEmpty, query)
        }
        try require(TranscriptSearch.matches(in: [], query: "text").isEmpty, "empty transcript")
    }

    private static func navigation() throws {
        try require(TranscriptSearch.nextIndex(current: nil, count: 3, backwards: false) == 0, "first")
        try require(TranscriptSearch.nextIndex(current: nil, count: 3, backwards: true) == 2, "last")
        try require(TranscriptSearch.nextIndex(current: 2, count: 3, backwards: false) == 0, "wrap next")
        try require(TranscriptSearch.nextIndex(current: 0, count: 3, backwards: true) == 2, "wrap previous")
        try require(TranscriptSearch.nextIndex(current: 0, count: 3, backwards: false) == 1, "next")
        try require(TranscriptSearch.nextIndex(current: 2, count: 3, backwards: true) == 1, "previous")
        try require(TranscriptSearch.nextIndex(current: 0, count: 1, backwards: false) == 0, "single")
        try require(TranscriptSearch.nextIndex(current: 0, count: 0, backwards: true) == nil, "empty")
        try require(TranscriptSearch.nextIndex(current: Int.max, count: 2, backwards: false) == 0, "stale")
        try require(TranscriptSearch.nextIndex(current: -1, count: 2, backwards: true) == 1, "negative")
    }

    private static func olderMessages() throws {
        var entries = (0..<250).map { entry("Message \($0)") }
        entries[4].translation = "older match"
        let matches = TranscriptSearch.matches(in: entries, query: "older match")
        try require(matches.count == 1 && matches[0].entryID == entries[4].id, "search entire transcript")
        let visible = TranscriptSearch.visibleCount(revealing: matches[0].entryID, in: entries, current: 100)
        try require(visible == 246 && entries.suffix(visible).first?.id == entries[4].id, "reveal older row")
        try require(
            TranscriptSearch.visibleCount(revealing: entries[249].id, in: entries, current: visible)
                == visible,
            "subsequent results must preserve loaded history")
        try require(
            TranscriptSearch.visibleCount(revealing: UUID(), in: entries, current: 100) == 100,
            "removed matches must not alter loaded history")
    }

    private static func cancellation() throws {
        try require(
            TranscriptSearch.matches(in: [entry("match match")], query: "match", isCancelled: { true })
                .isEmpty,
            "cancelled searches must not publish results")
    }

    private static func contextualFind() throws {
        let controller = AppFindController()
        let first = UUID()
        let second = UUID()
        try require(!controller.requestTranscriptFind(), "default find belongs to library")
        controller.focusTranscript(owner: first)
        try require(controller.requestTranscriptFind() && controller.request?.owner == first, "transcript")
        let generation = controller.request?.generation
        try require(
            controller.requestTranscriptFind() && controller.request?.generation != generation, "repeat")
        controller.focusLibrary()
        try require(!controller.requestTranscriptFind(), "list focus must return find to library")
        controller.findTranscript(owner: second)
        controller.releaseTranscript(owner: first)
        try require(
            controller.transcriptOwner == second && controller.request?.owner == second, "stale removal")
        controller.releaseTranscript(owner: second)
        try require(controller.request == nil && !controller.requestTranscriptFind(), "disposed owner")
    }

    private static func entry(_ original: String, translation: String? = nil) -> TranscriptEntry {
        TranscriptEntry(
            side: .caller, startFrame: 0, endFrame: 1, original: original, isFinal: true,
            translation: translation, translationStatus: translation == nil ? .notRequested : .translated)
    }
}
