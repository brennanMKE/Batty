// RootWindowView.swift

import SwiftUI

public struct RootWindowView: View {
    @State private var store: AppStateStore
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @AppStorage(SidebarPreference.hiddenKey) private var sidebarHidden: Bool = false

    public init(store: AppStateStore? = nil) {
        _store = State(initialValue: store ?? WorkspaceManager.shared.store)
    }

    public var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SessionSidebarView(store: store)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
        } detail: {
            SessionDetailView(store: store)
        }
        .environment(\.appStateStore, store)
        .environment(\.themeChrome, store.themeChrome)
        .task { setUpNotifier() }
        .onAppear {
            columnVisibility = sidebarHidden ? .detailOnly : .all
        }
        .onChange(of: columnVisibility) { _, newValue in
            sidebarHidden = (newValue == .detailOnly)
        }
        .onChange(of: sidebarHidden) { _, newValue in
            let target: NavigationSplitViewVisibility = newValue ? .detailOnly : .all
            guard columnVisibility != target else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                columnVisibility = target
            }
        }
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
}

public enum SidebarPreference {
    public static let hiddenKey = "co.sstools.Batty.sidebarHidden"
}
