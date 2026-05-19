// RootWindowView.swift

import AppKit
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
        .background(WindowChromeApplier(chrome: store.themeChrome))
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

/// Watches `ThemeChrome` and pushes its `windowBackground` into the
/// hosting `NSWindow`. Lives as a SwiftUI background view because that's
/// the cheapest hook into the window's lifetime from inside the SwiftUI
/// tree. When the chrome reverts to system default (palette has no
/// background), we restore `titlebarAppearsTransparent = false` so the
/// title bar gets its normal vibrant material back.
private struct WindowChromeApplier: NSViewRepresentable {
    let chrome: ThemeChrome

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Defer one runloop tick so the view is in a window before we
        // try to mutate the window. SwiftUI calls updateNSView before
        // the view-attach pass on first mount.
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            apply(palette: chrome.palette, to: window)
        }
    }

    private func apply(palette: ChromePalette, to window: NSWindow) {
        if let bg = palette.windowBackground {
            window.titlebarAppearsTransparent = true
            window.backgroundColor = NSColor(bg)
        } else {
            window.titlebarAppearsTransparent = false
            window.backgroundColor = nil
        }
    }
}
