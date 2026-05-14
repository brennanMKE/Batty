// HelpSidebarView.swift

import SwiftUI

struct HelpSidebarView: View {
    @Binding var selection: HelpSection.ID

    var body: some View {
        List(HelpCatalog.sections, selection: $selection) { section in
            Text(verbatim: section.title)
                .font(.system(size: 13))
                .tag(section.id)
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 220)
    }
}
