import SwiftUI

struct SettingsSurface<Content: View>: View {
    let width: CGFloat
    var maximumHeight: CGFloat = 680
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            content.padding(24)
        }
        .frame(width: width)
        .frame(maxHeight: maximumHeight)
        .fixedSize(horizontal: false, vertical: true)
    }
}
