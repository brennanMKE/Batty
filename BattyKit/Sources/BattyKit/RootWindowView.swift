// RootWindowView.swift

import SwiftUI

public struct RootWindowView: View {
    @State private var store: AppStateStore

    public init(store: AppStateStore = AppStateStore()) {
        _store = State(initialValue: store)
    }

    public var body: some View {
        NavigationSplitView {
            SessionSidebarView(store: store)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
        } detail: {
            SessionDetailView(store: store)
        }
    }
}
