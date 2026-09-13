import SwiftUI

struct LiveConversationWaveform: View {
    @Environment(\.appStrings) private var strings
    let caller: [Float]
    let agent: [Float]

    var body: some View {
        VStack(spacing: 8) {
            row(strings(.waveformCaller), samples: caller, color: .teal)
            row("Agent", samples: agent, color: .blue)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(strings(.waveformLive))
    }

    private func row(_ title: String, samples: [Float], color: Color) -> some View {
        HStack(spacing: 12) {
            Text(title).font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary).frame(width: 44, alignment: .leading)
            Canvas { context, size in
                let center = size.height / 2
                var baseline = Path()
                baseline.move(to: CGPoint(x: 0, y: center))
                baseline.addLine(to: CGPoint(x: size.width, y: center))
                context.stroke(baseline, with: .color(color.opacity(0.16)), lineWidth: 1)
                guard !samples.isEmpty else { return }
                let step = size.width / CGFloat(samples.count)
                for (index, sample) in samples.enumerated() where sample > 0 {
                    let amplitude = min(1, sqrt(CGFloat(sample)) * 2.2)
                    let height = max(2, amplitude * (size.height - 2))
                    let rect = CGRect(
                        x: CGFloat(index) * step, y: center - height / 2,
                        width: max(1, step * 0.58), height: height)
                    let opacity = 0.3 + 0.7 * Double(index + 1) / Double(samples.count)
                    context.fill(
                        Path(roundedRect: rect, cornerRadius: step / 2), with: .color(color.opacity(opacity)))
                }
            }.frame(height: 18)
        }
    }
}
