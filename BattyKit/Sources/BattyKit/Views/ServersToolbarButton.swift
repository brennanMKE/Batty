// ServersToolbarButton.swift

import SwiftUI

/// The only toolbar reader of the server registry, so a server change
/// re-renders this item rather than `SessionDetailView.body`.
struct ServersToolbarItem: View {
    let store: AppStateStore
    @AppStorage(SettingsPreference.alwaysShowServersKey) private var alwaysShow: Bool = SettingsPreference.defaultAlwaysShowServers

    var body: some View {
        let activeCount = store.servers.activeEntries.count
        if ServersToolbarVisibility.isVisible(flagOn: store.featureFlags.servers, activeCount: activeCount, alwaysShow: alwaysShow) {
            ServersToolbarButton(store: store, activeCount: activeCount)
        }
    }
}

/// Owns its popover state, so the state goes when the button leaves the
/// toolbar and a stale `true` can never reopen the popover.
private struct ServersToolbarButton: View {
    let store: AppStateStore
    let activeCount: Int
    @State private var isShown = false

    var body: some View {
        Button {
            isShown.toggle()
        } label: {
            Label("Servers", systemImage: "server.rack")
                .symbolRenderingMode(.hierarchical)
        }
        .help("Servers")
        .accessibilityIdentifier("toolbar.servers")
        .accessibilityLabel("Servers")
        .accessibilityValue(String(localized: "\(activeCount) running", comment: "Servers toolbar button: the number of running servers"))
        .popover(isPresented: $isShown, arrowEdge: .top) {
            ServersListView(store: store)
        }
    }
}
