import Foundation

struct TranscriptScrollFollow {
    private(set) var followsLatest = true
    private(set) var userIsScrolling = false

    func shouldFollow(searchVisible: Bool) -> Bool {
        followsLatest && !userIsScrolling && !searchVisible
    }

    mutating func userScrollBegan() {
        userIsScrolling = true
    }

    mutating func userScrollMoved(from previousOffset: Double, to offset: Double, atBottom: Bool) {
        guard userIsScrolling else { return }
        if offset < previousOffset - 1 {
            followsLatest = false
        } else if atBottom {
            followsLatest = true
        }
    }

    mutating func userScrollEnded(atBottom: Bool) {
        guard userIsScrolling else { return }
        userIsScrolling = false
        if atBottom { followsLatest = true }
    }

    mutating func showEarlier() {
        followsLatest = false
    }

    mutating func resume() {
        userIsScrolling = false
        followsLatest = true
    }
}
