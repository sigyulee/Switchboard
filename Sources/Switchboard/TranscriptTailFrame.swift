import SwiftUI

// Lazy stacks estimate total content height. The actual tail frame determines visibility.
struct TranscriptTailFrame: PreferenceKey {
    static let defaultValue = CGRect.null
    static let coordinateSpace = "transcript-viewport"
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if !next.isNull { value = next }
    }
}
