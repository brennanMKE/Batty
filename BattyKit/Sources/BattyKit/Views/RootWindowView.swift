// RootWindowView.swift

import AppKit
import SwiftUI

extension Notification.Name {
    public static let battyToggleSidebar = Notification.Name("co.sstools.Batty.toggleSidebar")
}

public struct RootWindowView: View {
    @State private var store: AppStateStore
    private let windowID: WindowID
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    /// Per-window sidebar visibility, persisted by the system with the scene
    /// (restored across relaunches for each window individually). Replaces the
    /// single app-wide `SidebarPreference.hiddenKey` `@AppStorage` property.
    @SceneStorage(SidebarPreference.sceneStorageKey) private var sidebarHidden: Bool = false
    /// One-time migration flag: on first launch after the move to
    /// `@SceneStorage`, seed the per-window value from the legacy global key
    /// so existing single-window users keep their hidden/shown state.
    @AppStorage(SidebarPreference.migratedKey) private var sidebarMigrationDone: Bool = false

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
            applyLegacySidebarMigrationIfNeeded()
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
        .onReceive(NotificationCenter.default.publisher(for: .battyToggleSidebar)) { _ in
            // Only the key content window responds — each RootWindowView
            // receives this notification, but only the key window should act.
            guard AppStateStore.shared.keyWindowRuntime()?.id == windowID else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                sidebarHidden.toggle()
            }
        }
    }

    /// Seeds `sidebarHidden` from the legacy app-wide `UserDefaults` key the
    /// first time this app version runs. After migration the flag is set so
    /// subsequent launches use the per-scene value directly.
    private func applyLegacySidebarMigrationIfNeeded() {
        let legacyValue = UserDefaults.standard.bool(forKey: SidebarPreference.hiddenKey)
        guard let seed = SidebarPreference.resolveInitialValue(
            migrationDone: sidebarMigrationDone,
            legacyValue: legacyValue
        ) else { return }
        sidebarHidden = seed
        sidebarMigrationDone = true
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
    /// Legacy app-wide `UserDefaults` key. Read during the one-time migration
    /// in `RootWindowView.applyLegacySidebarMigrationIfNeeded`.
    public static let hiddenKey = "co.sstools.Batty.sidebarHidden"
    /// `@SceneStorage` key for per-window sidebar visibility. Each window
    /// independently stores and restores its sidebar state.
    public static let sceneStorageKey = "sidebarHidden"
    /// `@AppStorage` flag that marks the one-time migration from the legacy
    /// global key to per-window `@SceneStorage`.
    public static let migratedKey = "co.sstools.Batty.sidebarMigrated"

    /// Returns the initial sidebar-hidden value that a window should adopt,
    /// given the migration state and the value stored under the legacy key.
    /// Pure function — no `UserDefaults` reads — for unit testing.
    public static func resolveInitialValue(
        migrationDone: Bool,
        legacyValue: Bool
    ) -> Bool? {
        // When migration is already done, the caller keeps whatever
        // @SceneStorage restored — nil signals "no override needed."
        guard !migrationDone else { return nil }
        return legacyValue
    }
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
