import BridgeCore
import RecorderKit
import SwiftUI

struct RecordingInfoButton: View {
    @Environment(\.appTypography) private var typography
    @Environment(\.appStrings) private var strings
    @ViewState private var showingInfo = false
    let item: RecordingItem

    var body: some View {
        IconButton("info.circle", label: strings(.libraryRecordingInfo)) { showingInfo.toggle() }
            .popover(isPresented: $showingInfo, arrowEdge: .trailing) {
                RecordingInformation(item: item)
                    .environment(\.appStrings, strings).environment(\.locale, strings.locale)
                    .environment(\.appTypography, typography)
            }
    }
}

private struct RecordingInformation: View {
    @Environment(\.appTypography) private var typography
    @Environment(\.appStrings) private var strings
    let item: RecordingItem
    @ViewState private var summaries: [RecordingGapSummary]?
    @ViewState private var error: String?
    @ViewState private var expandedSide: AudioSide?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(item.manifest.title).font(typography.section)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 8) {
                    Text(strings(.libraryRecordedAt)).font(typography.caption).foregroundStyle(.secondary)
                    Text(
                        item.manifest.createdAt.formatted(
                            .dateTime.year().month().day().hour().minute().second()
                                .timeZone(.specificName(.short)).locale(strings.locale))
                    )
                    .fixedSize(horizontal: false, vertical: true)
                    LabeledContent(strings(.sessionDuration), value: durationText(item.manifest.duration))
                }
                Divider()
                Text(strings(.libraryMissingAudio)).font(typography.section)
                if let summaries {
                    if summaries.allSatisfy({ $0.intervalCount == 0 }) {
                        Text(strings(.libraryNoMissingAudio)).foregroundStyle(.secondary)
                    } else {
                        ForEach(summaries, id: \.side) { summary in
                            MissingAudioSection(
                                summary: summary,
                                expanded: Binding(
                                    get: { expandedSide == summary.side },
                                    set: { expandedSide = $0 ? summary.side : nil }))
                        }
                    }
                } else if let error {
                    Text(error).foregroundStyle(.orange)
                } else {
                    ProgressView()
                }
                if let code = item.manifest.failureCode, let failure = MediaFailure(rawValue: code) {
                    Text(strings.error(failure)).font(typography.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }.font(typography.body).textSelection(.enabled).padding(16)
        }.frame(width: typography.textSize == .largest ? 400 : 360).frame(maxHeight: 520)
            .fixedSize(horizontal: false, vertical: true)
            .onChange(of: item.manifest, initial: true) {
                do {
                    summaries = try AudioSide.allCases.map {
                        try RecordingGapSummary(manifest: item.manifest, side: $0)
                    }
                    error = nil
                } catch {
                    summaries = nil
                    self.error = strings.error(error)
                }
            }
    }
}

private struct MissingAudioSection: View {
    @Environment(\.appTypography) private var typography
    @Environment(\.appStrings) private var strings
    let summary: RecordingGapSummary
    @Binding var expanded: Bool
    @ViewState private var page = 0
    private let pageSize = 20
    private var start: Int {
        min(page, max(0, (summary.intervalCount - 1) / pageSize)) * pageSize
    }
    private var end: Int { min(start + pageSize, summary.intervalCount) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(summary.side == .caller ? strings(.roleCaller) : "Agent").font(typography.section)
                Spacer()
                Text(
                    strings(.libraryGapCount, summary.intervalCount.formatted(.number.locale(strings.locale)))
                )
                Text(strings(.libraryGapTotal, length(summary.duration))).foregroundStyle(.secondary)
            }.accessibilityElement(children: .combine)
            if summary.intervalCount > 0 {
                DisclosureGroup(strings(.libraryGapDetails), isExpanded: $expanded) {
                    VStack(alignment: .leading, spacing: 12) {
                        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                            GridRow {
                                Text(strings(.libraryGapPosition))
                                Text(strings(.libraryGapLength))
                            }.font(typography.caption).foregroundStyle(.secondary)
                            ForEach(start..<end, id: \.self) { index in
                                let gap = summary.gaps[index]
                                GridRow {
                                    Text(position(gap.startFrame))
                                    Text(length(Double(gap.frames) / summary.sampleRate))
                                        .gridColumnAlignment(.trailing)
                                }.monospacedDigit().accessibilityElement(children: .combine)
                            }
                        }
                        if summary.intervalCount > pageSize {
                            HStack {
                                IconButton("chevron.left", label: strings(.libraryPreviousIntervals)) {
                                    page -= 1
                                }
                                .disabled(page == 0)
                                Spacer()
                                Text(
                                    strings(
                                        .libraryGapRange, number(start + 1), number(end),
                                        number(summary.intervalCount))
                                )
                                .font(typography.caption).foregroundStyle(.secondary)
                                Spacer()
                                IconButton("chevron.right", label: strings(.libraryNextIntervals)) {
                                    page += 1
                                }
                                .disabled(end == summary.intervalCount)
                            }
                        }
                    }.padding(.top, 8)
                }
                .accessibilityLabel(
                    strings(.libraryGapDetails) + ": "
                        + (summary.side == .caller ? strings(.roleCaller) : "Agent"))
            }
        }.onChange(of: summary) { page = 0 }
    }

    private func number(_ value: Int) -> String { value.formatted(.number.locale(strings.locale)) }

    private func length(_ seconds: Double) -> String {
        if seconds > 0 && seconds < 0.001 { return strings(.libraryLessThanMillisecond) }
        let formatter = MeasurementFormatter()
        formatter.locale = strings.locale
        formatter.unitOptions = .providedUnit
        formatter.unitStyle = .medium
        formatter.numberFormatter.maximumFractionDigits = 3
        return formatter.string(from: Measurement(value: seconds, unit: UnitDuration.seconds))
    }

    private func position(_ frame: Int64) -> String {
        // Validated recording metadata has a 48 kHz timeline; integer arithmetic preserves tiny offsets.
        let seconds = frame / 48_000
        let milliseconds = (frame % 48_000) * 1_000 / 48_000
        return String(format: "%@.%03lld", durationText(Double(seconds)), milliseconds)
    }
}
