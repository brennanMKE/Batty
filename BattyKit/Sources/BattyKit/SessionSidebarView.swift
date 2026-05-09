// SessionSidebarView.swift

import SwiftUI

public struct SessionSidebarView: View {
    @Bindable public var store: AppStateStore

    public init(store: AppStateStore) {
        self.store = store
    }

    public var body: some View {
        List(selection: $store.selectedSessionID) {
            ForEach(store.sessions) { session in
                SessionRow(session: session)
                    .tag(session.id as UUID?)
            }
            .onMove { source, destination in
                store.moveSessions(fromOffsets: source, toOffset: destination)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Batty")
        .toolbar {
            ToolbarItem {
                Button {
                    store.addSession()
                } label: {
                    Label("New Session", systemImage: "plus")
                }
                .help("New Session")
            }
        }
    }
}

private struct SessionRow: View {
    @Bindable var session: SessionRuntime

    var body: some View {
        Label {
            Text(displayTitle).lineLimit(1)
        } icon: {
            Image(systemName: "rectangle.split.3x1")
                .foregroundStyle(.secondary)
        }
    }

    private var displayTitle: String {
        let live = session.terminal.title
        return live.isEmpty ? session.title : live
    }
}
