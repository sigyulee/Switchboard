// SPDX-License-Identifier: AGPL-3.0-only
import BridgeCore
import Foundation

struct TranscriptSearchMatch: Hashable, Sendable {
    enum Field: Hashable, Sendable { case original, translation }
    let entryID: UUID
    let field: Field
    let range: NSRange
}

enum TranscriptSearch {
    static func matches(
        in entries: [TranscriptEntry], query: String,
        isCancelled: @Sendable () -> Bool = { false }
    ) -> [TranscriptSearchMatch] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        var result: [TranscriptSearchMatch] = []
        for entry in entries {
            guard !isCancelled() else { return [] }
            for (field, text) in [
                (TranscriptSearchMatch.Field.original, entry.original),
                (.translation, entry.translation ?? ""),
            ] {
                var start = text.startIndex
                while start < text.endIndex,
                    let range = text.range(
                        of: query, options: [.caseInsensitive, .diacriticInsensitive],
                        range: start..<text.endIndex, locale: Locale(identifier: "en_US_POSIX"))
                {
                    guard !isCancelled(), range.lowerBound < range.upperBound else { return [] }
                    result.append(
                        TranscriptSearchMatch(
                            entryID: entry.id, field: field, range: NSRange(range, in: text)))
                    start = range.upperBound
                }
            }
        }
        return result
    }

    static func nextIndex(current: Int?, count: Int, backwards: Bool) -> Int? {
        guard count > 0 else { return nil }
        guard let current, (0..<count).contains(current) else { return backwards ? count - 1 : 0 }
        if backwards { return current == 0 ? count - 1 : current - 1 }
        return current == count - 1 ? 0 : current + 1
    }

    static func visibleCount(
        revealing entryID: UUID, in entries: [TranscriptEntry], current: Int
    ) -> Int {
        guard let index = entries.firstIndex(where: { $0.id == entryID }) else { return max(0, current) }
        return max(current, entries.count - index)
    }
}
