import SwiftUI

struct RecordingWaveform: View {
    @Environment(\.appStrings) private var strings
    let samples: [Float]
    let progress: Double
    let seek: (Double) -> Void
    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                guard !samples.isEmpty else { return }
                let peak = max(0.05, Double(samples.max() ?? 1))
                let step = size.width / Double(samples.count)
                for index in samples.indices {
                    let amplitude = min(1, Double(samples[index]) / peak)
                    let height = max(2, amplitude * size.height)
                    let rectangle = CGRect(
                        x: Double(index) * step, y: (size.height - height) / 2, width: max(1, step - 1),
                        height: height)
                    let color =
                        Double(index) / Double(samples.count) <= progress
                        ? Color.accentColor : Color.secondary.opacity(0.3)
                    context.fill(Path(roundedRect: rectangle, cornerRadius: 1), with: .color(color))
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { value in
                    seek(max(0, min(1, value.location.x / max(1, geometry.size.width))))
                })
        }
        .frame(height: 44)
        .accessibilityHidden(true)
    }
}
