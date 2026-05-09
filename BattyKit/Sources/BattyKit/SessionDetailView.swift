// SessionDetailView.swift

import SwiftUI

public struct SessionDetailView: View {
    public let store: AppStateStore

    public init(store: AppStateStore) {
        self.store = store
    }

    public var body: some View {
        ZStack {
            ForEach(store.sessions) { session in
                TerminalSurfaceView(context: session.terminal)
                    .opacity(session.id == store.selectedSessionID ? 1 : 0)
                    .allowsHitTesting(session.id == store.selectedSessionID)
            }
            if store.selectedSession == nil {
                ContentUnavailableView(
                    "No Session Selected",
                    systemImage: "rectangle.split.3x1",
                    description: Text("Pick a session in the sidebar or create one with the + button.")
                )
            }
        }
        .frame(minWidth: 600, minHeight: 400)
        .navigationTitle(navigationTitle)
    }

    private var navigationTitle: String {
        guard let session = store.selectedSession else { return "Batty" }
        let live = session.terminal.title
        return live.isEmpty ? session.title : live
    }
}
