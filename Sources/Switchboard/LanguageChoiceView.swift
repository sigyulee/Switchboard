import BridgeCore
import SwiftUI

struct LanguageChoiceView: View {
    let choose: (ApplicationLanguage) -> Void

    var body: some View {
        VStack(spacing: 28) {
            SwitchboardMark().frame(width: 64, height: 64)
            Text("Switchboard").font(.system(size: 28, weight: .semibold))
            VStack(spacing: 12) {
                ForEach(ApplicationLanguage.allCases) { language in
                    Button {
                        choose(language)
                    } label: {
                        HStack {
                            Text(language.nativeName).font(.system(size: 17, weight: .medium))
                            Spacer()
                            Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        }.padding(.horizontal, 16).padding(.vertical, 10)
                    }.buttonStyle(.bordered).controlSize(.large)
                }
            }.frame(width: 280)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minWidth: 680, minHeight: 620)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
