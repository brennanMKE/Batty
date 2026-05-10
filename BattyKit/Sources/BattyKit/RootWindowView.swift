// RootWindowView.swift

import SwiftUI

public struct RootWindowView: View {
    @State private var store: AppStateStore
    @AppStorage(SidebarPreference.hiddenKey) private var sidebarHidden: Bool = false

    public init(store: AppStateStore? = nil) {
        _store = State(initialValue: store ?? WorkspaceManager.shared.store)
    }

    public var body: some View {
        NavigationSplitView(columnVisibility: columnVisibilityBinding) {
            SessionSidebarView(store: store)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
        } detail: {
            SessionDetailView(store: store)
        }
        .focusedSceneValue(\.appStateStore, store)
        .environment(\.appStateStore, store)
        .task { setUpNotifier() }
    }

    private func setUpNotifier() {
        guard store.notifier == nil else { return }
        let notifier = BellNotifier { [weak store] entryID in
            guard let store else { return }
            if let entry = store.bellFeed.entries.first(where: { $0.id == entryID }) {
                store.markBellSeen(id: entryID)
                store.jumpToBellEntry(entry)
            }
        }
        store.notifier = notifier
        notifier.ensureAuthorization()
    }

    private var columnVisibilityBinding: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { sidebarHidden ? .detailOnly : .all },
            set: { newValue in
                sidebarHidden = (newValue == .detailOnly)
            }
        )
    }
}

public enum SidebarPreference {
    public static let hiddenKey = "co.sstools.Batty.sidebarHidden"
}
