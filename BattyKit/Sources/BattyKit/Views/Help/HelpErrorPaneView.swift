// HelpErrorPaneView.swift

import SwiftUI

struct HelpErrorPaneView: View {
    let error: Error
    let sectionTitle: String

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Couldn't load \(sectionTitle)")
                    .font(.system(size: 13, weight: .semibold))
                Text(verbatim: error.localizedDescription)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
    }
}
