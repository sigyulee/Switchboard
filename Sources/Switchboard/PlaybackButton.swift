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
            action: { play(source) }
        ) {
            Picker(strings(.librarySources), selection: Binding(get: { source }, set: { play($0) })) {
                ForEach(PlaybackSource.allCases, id: \.self) { choice in
                    Text(strings(choice.title)).tag(choice)
                }
            }.pickerStyle(.inline).labelsHidden()
        }
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
