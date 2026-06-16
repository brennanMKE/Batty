// RootWindowView.swift

import AppKit
import SwiftUI

public struct RootWindowView: View {
    @State private var store: AppStateStore
    private let windowID: WindowID
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @AppStorage(SidebarPreference.hiddenKey) private var sidebarHidden: Bool = false

    public init(windowID: WindowID, store: AppStateStore? = nil) {
        self.windowID = windowID
        _store = State(initialValue: store ?? AppStateStore.shared)
    }

    public var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SessionSidebarView(store: store, windowID: windowID)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
        } detail: {
            SessionDetailView(store: store, windowID: windowID)
        }
        .environment(\.appStateStore, store)
        .environment(\.themeChrome, store.themeChrome)
        .background(WindowChromeApplier(palette: store.themeChrome.palette))
        .background(WindowIDRegistrar(windowID: windowID))
        .task { setUpNotifier() }
        .task { UITestDriver.runIfNeeded(store: store) }
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

/// Themes the host `NSWindow` to match the active palette: paints the
/// window background and makes the title bar transparent so it adopts the
/// themed color uniformly. Reverts to the system default chrome (vibrant
/// title-bar material) when no theme is active.
private struct WindowChromeApplier: NSViewRepresentable {
    let palette: ChromePalette

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            apply(palette: palette, to: window)
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
