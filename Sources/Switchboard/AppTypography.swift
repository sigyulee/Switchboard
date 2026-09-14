import AppKit
import SwiftUI

enum AppTextSize: String, CaseIterable, Identifiable {
    case standard, larger, largest
    var id: Self { self }
    var scale: CGFloat {
        switch self {
        case .standard: 1
        case .larger: 1.2
        case .largest: 1.4
        }
    }
    var label: TextKey {
        switch self {
        case .standard: .settingsTextStandard
        case .larger: .settingsTextLarger
        case .largest: .settingsTextLargest
        }
    }
}

struct AppTypography {
    var textSize: AppTextSize = .larger

    var title: Font { font(.title1, weight: .semibold) }
    var panelTitle: Font { font(.title2, weight: .semibold) }
    var section: Font { font(.headline, weight: .semibold) }
    var row: Font { font(.body, weight: .medium) }
    var body: Font { font(.body) }
    var caption: Font { font(.callout) }
    var controlSide: CGFloat {
        max(36, ceil(NSFont.preferredFont(forTextStyle: .title2).pointSize * textSize.scale + 14))
    }

    // macOS text styles supply platform metrics; the app preference supplies text scaling.
    // Keep controls and content on the same scale without reading private system preferences.
    private func font(_ style: NSFont.TextStyle, weight: Font.Weight = .regular) -> Font {
        .system(size: NSFont.preferredFont(forTextStyle: style).pointSize * textSize.scale, weight: weight)
    }
}

private struct AppTypographyKey: EnvironmentKey {
    static let defaultValue = AppTypography()
}

extension EnvironmentValues {
    var appTypography: AppTypography {
        get { self[AppTypographyKey.self] }
        set { self[AppTypographyKey.self] = newValue }
    }
}
