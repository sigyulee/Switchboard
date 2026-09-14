import AppKit
import BridgeCore
import SwiftUI

struct TranscriptMessages: View {
    @Environment(\.appTypography) private var typography
    @Environment(\.appStrings) private var strings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AppFindController.self) private var findController
    let transcriptID: UUID
    let entries: [TranscriptEntry]
    var seek: ((Double) -> Void)? = nil
    var isProcessing = false
    @ViewState private var followsLatest = true
    @ViewState private var visibleCount = 100
    @ViewState private var searchVisible = false
    @ViewState private var query = ""
    @ViewState private var matches: [TranscriptSearchMatch] = []
    @ViewState private var matchesByEntry: [UUID: [TranscriptSearchMatch]] = [:]
    @ViewState private var selectedIndex: Int?
    @ViewState private var retainedSelection: TranscriptSearchMatch?
    @ViewState private var searchedQuery = ""
    @ViewState private var isSearching = false
    @ViewState private var searchGeneration = UUID()
    @ViewState private var scrollRequest: ScrollRequest?
    @ViewState private var rangeRevealID: UUID?
    @FocusState private var searchFocused: Bool
    @FocusState private var contentFocused: Bool

    private struct SearchInput: Equatable {
        let entries: [TranscriptEntry]
        let query: String
        let visible: Bool
    }

    private struct ScrollRequest: Equatable {
        let match: TranscriptSearchMatch
        let generation = UUID()
    }

    private var selectedMatch: TranscriptSearchMatch? {
        guard let selectedIndex, matches.indices.contains(selectedIndex) else { return nil }
        return matches[selectedIndex]
    }

    var body: some View {
        VStack(spacing: 0) {
            if searchVisible {
                searchBar
                Divider()
            }
            messages
        }
        .onChange(of: findController.request) { _, request in
            guard request?.owner == transcriptID else { return }
            searchVisible = true
            searchFocused = true
        }
        .onChange(of: searchFocused) { _, focused in
            if focused { findController.focusTranscript(owner: transcriptID) }
        }
        .onChange(of: contentFocused) { _, focused in
            if focused { findController.focusTranscript(owner: transcriptID) }
        }
        .simultaneousGesture(
            TapGesture().onEnded { findController.focusTranscript(owner: transcriptID) }
        )
        .task(id: SearchInput(entries: entries, query: query, visible: searchVisible)) {
            await updateSearch()
        }
        .onDisappear {
            searchGeneration = UUID()
            findController.releaseTranscript(owner: transcriptID)
        }
    }

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 16) {
                    if entries.count > visibleCount {
                        IconButton("chevron.up", label: strings(.transcriptEarlierMessages)) {
                            visibleCount = min(entries.count, visibleCount + 100)
                            findController.focusTranscript(owner: transcriptID)
                        }
                    }
                    if entries.isEmpty {
                        Text(strings(.transcriptNoMessages)).font(typography.body).foregroundStyle(
                            .tertiary
                        )
                        .frame(maxWidth: .infinity).padding(.top, 48)
                    }
                    ForEach(entries.suffix(visibleCount)) { entry in
                        TranscriptMessage(
                            entry: entry, seek: seek, matches: matchesByEntry[entry.id] ?? [],
                            selectedMatch: selectedMatch, revealID: rangeRevealID,
                            focus: { findController.focusTranscript(owner: transcriptID) }
                        ).id(entry.id)
                    }
                    Color.clear.frame(height: 1).id("latest")
                }.padding(24)
            }
            .focusable().focusEffectDisabled().focused($contentFocused)
            .accessibilityLabel(strings(.libraryTranscript))
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentSize.height - geometry.visibleRect.maxY <= 32
            } action: { _, atBottom in
                if !searchVisible { followsLatest = atBottom }
            }
            .onChange(of: entries) {
                if followsLatest && !searchVisible { proxy.scrollTo("latest", anchor: .bottom) }
            }
            .task(id: scrollRequest) {
                guard let request = scrollRequest else { return }
                // The earlier suffix must participate in layout before scrolling to its field.
                await Task.yield()
                guard !Task.isCancelled, scrollRequest == request else { return }
                proxy.scrollTo(request.match.entryID, anchor: .top)
                await Task.yield()
                guard !Task.isCancelled, scrollRequest == request else { return }
                rangeRevealID = request.generation
            }
            .overlay(alignment: .bottom) {
                if isProcessing || (!followsLatest && !entries.isEmpty) {
                    TranscriptLatestButton(isProcessing: isProcessing) {
                        findController.focusTranscript(owner: transcriptID)
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                            proxy.scrollTo("latest", anchor: .bottom)
                        }
                    }.padding(12)
                }
            }
        }
    }

    private var searchBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField(strings(.transcriptSearch), text: $query)
                    .textFieldStyle(.plain).focused($searchFocused)
                    .accessibilityLabel(strings(.transcriptSearch))
                    .onSubmit { moveMatch(backwards: false) }
                    .onExitCommand(perform: closeSearch)
                if !query.isEmpty {
                    IconButton("xmark.circle.fill", label: strings(.transcriptSearchClear)) {
                        query = ""
                        searchFocused = true
                    }
                }
            }
            .padding(8)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
            }
            HStack(spacing: 8) {
                if isSearching {
                    ProgressView().controlSize(.mini).accessibilityLabel(strings(.transcriptSearch))
                } else if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(
                        matches.isEmpty
                            ? strings(.transcriptSearchNoResults)
                            : strings(.transcriptSearchCount, (selectedIndex ?? 0) + 1, matches.count)
                    ).font(typography.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                IconButton("chevron.up", label: strings(.transcriptSearchPrevious)) {
                    moveMatch(backwards: true)
                }.disabled(matches.isEmpty || isSearching)
                IconButton("chevron.down", label: strings(.transcriptSearchNext)) {
                    moveMatch(backwards: false)
                }.disabled(matches.isEmpty || isSearching)
                IconButton("xmark", label: strings(.transcriptSearchClose), action: closeSearch)
            }
        }
        .font(typography.body).padding(.horizontal, 24).padding(.vertical, 12)
    }

    private func closeSearch() {
        searchVisible = false
        searchFocused = false
        query = ""
        matches = []
        matchesByEntry = [:]
        selectedIndex = nil
        retainedSelection = nil
        scrollRequest = nil
        contentFocused = true
    }

    private func moveMatch(backwards: Bool) {
        findController.focusTranscript(owner: transcriptID)
        selectedIndex = TranscriptSearch.nextIndex(
            current: selectedIndex, count: matches.count, backwards: backwards)
        revealSelectedMatch()
    }

    private func revealSelectedMatch() {
        guard let selectedMatch else { return }
        retainedSelection = selectedMatch
        visibleCount = TranscriptSearch.visibleCount(
            revealing: selectedMatch.entryID, in: entries, current: visibleCount)
        scrollRequest = ScrollRequest(match: selectedMatch)
    }

    private func updateSearch() async {
        let generation = UUID()
        searchGeneration = generation
        let queryChanged = searchedQuery != query
        searchedQuery = query
        let previous = queryChanged ? nil : retainedSelection
        if queryChanged { retainedSelection = nil }
        matches = []
        matchesByEntry = [:]
        selectedIndex = nil
        scrollRequest = nil
        guard searchVisible, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            isSearching = false
            return
        }
        isSearching = true
        if queryChanged {
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
        }
        guard !Task.isCancelled else { return }
        let entries = entries
        let query = query
        let work = Task.detached(priority: .userInitiated) {
            TranscriptSearch.matches(in: entries, query: query, isCancelled: { Task.isCancelled })
        }
        let result = await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
        guard !Task.isCancelled, searchGeneration == generation else { return }
        matches = result
        matchesByEntry = Dictionary(grouping: result, by: \.entryID)
        selectedIndex = previous.flatMap { result.firstIndex(of: $0) } ?? (result.isEmpty ? nil : 0)
        isSearching = false
        if selectedMatch != previous { revealSelectedMatch() }
    }
}

private struct TranscriptSearchAnchor: Hashable {
    let entryID: UUID
    let field: TranscriptSearchMatch.Field
}

struct TranscriptMessage: View {
    @Environment(\.appTypography) private var typography
    @Environment(\.appStrings) private var strings
    let entry: TranscriptEntry
    var seek: ((Double) -> Void)? = nil
    var matches: [TranscriptSearchMatch] = []
    var selectedMatch: TranscriptSearchMatch?
    var revealID: UUID?
    var focus: () -> Void = {}
    var body: some View {
        HStack {
            if entry.side == .agent { Spacer(minLength: 32) }
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text(entry.side == .agent ? "Agent" : strings(.roleCaller)).font(
                        typography.caption.weight(.semibold))
                    if let seek {
                        Button(durationText(Double(entry.startFrame) / 48_000)) {
                            seek(Double(entry.startFrame) / 48_000)
                        }
                        .buttonStyle(.plain).font(typography.caption.monospacedDigit()).foregroundStyle(
                            .secondary)
                    } else {
                        Text(durationText(Double(entry.startFrame) / 48_000)).font(
                            typography.caption.monospacedDigit()
                        ).foregroundStyle(.secondary)
                    }
                }
                messageText(entry.original, field: .original, secondary: !entry.isFinal)
                    .id(TranscriptSearchAnchor(entryID: entry.id, field: .original))
                if let translation = entry.translation {
                    messageText(translation, field: .translation, secondary: true)
                        .id(TranscriptSearchAnchor(entryID: entry.id, field: .translation))
                        .padding(.top, 10)
                        .overlay(alignment: .top) { Divider().opacity(0.5) }
                }
            }
            .textSelection(.enabled).padding(16)
            .background(
                entry.side == .agent ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.045),
                in: RoundedRectangle(cornerRadius: 12)
            )
            .frame(maxWidth: 500, alignment: entry.side == .agent ? .trailing : .leading)
            if entry.side == .caller { Spacer(minLength: 32) }
        }.frame(maxWidth: .infinity)
    }

    @ViewBuilder private func messageText(_ text: String, field: TranscriptSearchMatch.Field, secondary: Bool)
        -> some View
    {
        let fieldMatches = matches.filter { $0.field == field }
        if fieldMatches.isEmpty {
            Text(text).font(typography.body).foregroundStyle(secondary ? .secondary : .primary)
        } else {
            let current = selectedMatch.flatMap { $0.entryID == entry.id && $0.field == field ? $0 : nil }
            TranscriptSearchText(
                text: text,
                font: .systemFont(
                    ofSize: NSFont.preferredFont(forTextStyle: .body).pointSize * typography.textSize.scale),
                secondary: secondary, matches: fieldMatches, selected: current,
                revealID: current == nil ? nil : revealID, focus: focus)
        }
    }

}

private struct TranscriptLatestButton: View {
    @Environment(\.appTypography) private var typography
    @Environment(\.appStrings) private var strings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let isProcessing: Bool
    let action: () -> Void

    private var label: String {
        strings(isProcessing ? .transcriptProcessingLatest : .transcriptNewMessages)
    }

    var body: some View {
        Button(action: action) {
            Group {
                if isProcessing {
                    if reduceMotion {
                        Image(systemName: "ellipsis")
                    } else {
                        TimelineView(.animation(minimumInterval: 1.0 / 24)) { context in
                            Canvas { canvas, size in
                                let phase =
                                    context.date.timeIntervalSinceReferenceDate
                                    .truncatingRemainder(dividingBy: 1.2) / 1.2
                                for index in 0..<3 {
                                    let wave = (sin((phase - Double(index) / 5) * .pi * 2) + 1) / 2
                                    let point = CGRect(
                                        x: size.width / 2 + CGFloat(index - 1) * 6 - 1.5,
                                        y: size.height / 2 - 1.5 - wave * 2, width: 3, height: 3)
                                    canvas.fill(
                                        Path(ellipseIn: point),
                                        with: .color(.secondary.opacity(0.4 + wave * 0.6)))
                                }
                            }
                        }
                    }
                } else {
                    Image(systemName: "arrow.down")
                }
            }
            .font(typography.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .frame(width: 32, height: 32)
            .hoverBackground(cornerRadius: 16)
            .background(.regularMaterial, in: Circle())
            .overlay(Circle().strokeBorder(.primary.opacity(0.08)))
            .shadow(color: .black.opacity(0.05), radius: 2, y: 1)
            .contentShape(Circle())
        }
        .buttonStyle(.plain).accessibilityLabel(label).help(label)
    }
}
