// HelpSuccessPaneView.swift

import SwiftUI
import Textual

struct HelpSuccessPaneView: View {
    let text: String

    var body: some View {
        ScrollView(.vertical) {
            StructuredText(
                markdown: text,
                baseURL: bundleHelpDirectory()
            )
            .textual.textSelection(.enabled)
            .font(.system(size: 12))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
    }

    private func bundleHelpDirectory() -> URL? {
        if let url = Bundle.main.url(forResource: "Help", withExtension: nil) {
            return url
        }
        return Bundle.main.resourceURL
    }
}
