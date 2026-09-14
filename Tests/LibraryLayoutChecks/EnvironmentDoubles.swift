import AppKit
import SwiftUI

// The layout bridge forwards these environment values without depending on their application-specific types.
struct LayoutStrings { var language: String }
struct LayoutTypography { var scale: Double }
private struct LayoutStringsKey: EnvironmentKey {
    static let defaultValue = LayoutStrings(language: "default")
}
private struct LayoutTypographyKey: EnvironmentKey {
    static let defaultValue = LayoutTypography(scale: 0)
}
extension EnvironmentValues {
    var appStrings: LayoutStrings {
        get { self[LayoutStringsKey.self] }
        set { self[LayoutStringsKey.self] = newValue }
    }
    var appTypography: LayoutTypography {
        get { self[LayoutTypographyKey.self] }
        set { self[LayoutTypographyKey.self] = newValue }
    }
}

@MainActor final class EnvironmentProbeView: NSView {
    var language = ""
    var scale = 0.0
    var locale = ""
}

struct EnvironmentProbe: NSViewRepresentable {
    @Environment(\.appStrings) private var strings
    @Environment(\.appTypography) private var typography
    @Environment(\.locale) private var locale

    func makeNSView(context: Context) -> EnvironmentProbeView { EnvironmentProbeView() }
    func updateNSView(_ nsView: EnvironmentProbeView, context: Context) {
        nsView.language = strings.language
        nsView.scale = typography.scale
        nsView.locale = locale.identifier
    }
}
