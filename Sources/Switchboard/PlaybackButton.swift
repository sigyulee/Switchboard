import SwiftUI

struct PlaybackButton: View {
    @Environment(\.appStrings) private var strings
    let source: PlaybackSource
    var preparing = false
    let play: (PlaybackSource) -> Void

    var body: some View {
        SplitActionButton(
            title: strings(preparing ? .libraryPreparing : source == .mix ? .libraryPlay : source.title),
            systemImage: "play.fill", menuLabel: strings(.librarySources),
            action: { play(source) },
            options: PlaybackSource.allCases.map { choice in
                SplitMenuOption(
                    id: choice.title.rawValue, title: strings(choice.title),
                    selected: source == choice, action: { play(choice) })
            }
        )
        .accessibilityValue(strings(source.title))
    }
}

extension PlaybackSource {
    fileprivate var title: TextKey {
        switch self {
        case .mix: .libraryPlayMix
        case .caller: .libraryPlayCaller
        case .agent: .libraryPlayAgent
        }
    }
}
