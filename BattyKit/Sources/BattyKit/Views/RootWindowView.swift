// RootWindowView.swift

import AppKit
import OSLog
import SwiftUI

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "RootWindowView")

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
        .background(WindowLifecycleController(windowID: windowID, store: store))
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

/// Manages the window lifecycle for a single content window:
///   - wires `WindowRuntime.closeWindowCallback` so a "last session closed"
///     event closes the NSWindow;
///   - installs itself as `NSWindowDelegate` to intercept the close button
///     (`windowShouldClose`) and prompt when live sessions are present;
///   - tears down the window's terminal host and registry entries on close.
///
/// Placed in the SwiftUI tree as an invisible `NSViewRepresentable` so it
/// has access to the hosting `NSWindow` via `updateNSView`. Follows the
/// same deferred pattern as `WindowChromeApplier` and `WindowIDRegistrar`:
/// all AppKit side-effects are dispatched off the update pass to avoid
/// running inside the layout pass (`docs/swiftui-observation-rules.md`
/// AppKit interop section).
private struct WindowLifecycleController: NSViewRepresentable {
    let windowID: WindowID
    let store: AppStateStore

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let id = windowID
        let appStore = store
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            // Install delegate (idempotent — coordinator is retained by context).
            if window.delegate == nil || !(window.delegate is WindowDelegate) {
                window.delegate = context.coordinator
            }
            // Wire closeWindowCallback on the runtime so onAllSessionsClosed
            // (last session closed) closes the NSWindow.
            let runtime = appStore.windowRuntime(for: id)
            if runtime.closeWindowCallback == nil {
                runtime.closeWindowCallback = { [weak window] in
                    logger.info("closeWindowCallback: closing windowID=\(id.value, privacy: .public)")
                    window?.performClose(nil)
                }
            }
            // Sync the store's initial occlusion state — the delegate's
            // windowDidChangeOcclusionState only fires on a subsequent
            // transition, so a window created already occluded (or this
            // being the first time occlusion is wired up for it) needs an
            // explicit read here. Idempotent at the store (#0288).
            TerminalHostStore.shared.setWindowOcclusionVisible(
                window.occlusionState.contains(.visible),
                forWindowID: id
            )
        }
    }

    func makeCoordinator() -> WindowDelegate {
        WindowDelegate(windowID: windowID, store: store)
    }
}

/// `NSWindowDelegate` for a content window. Handles confirmation on close and
/// teardown of the window's terminal host and registry entries.
final class WindowDelegate: NSObject, NSWindowDelegate {
    private let windowID: WindowID
    private let store: AppStateStore

    init(windowID: WindowID, store: AppStateStore) {
        self.windowID = windowID
        self.store = store
    }

    /// Intercepts the close button and the programmatic `performClose(_:)` path.
    /// Prompts when any tab in the window has a running process and the
    /// "Confirm on close" setting is enabled — same contract as `QuitConfirmation`.
    /// Returns `true` to allow the close; `false` to cancel it.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        let runtime = store.windowRuntime(for: windowID)
        guard QuitConfirmation.windowNeedsConfirmClose(window: runtime) else {
            return true
        }
        let busyCount = runtime.sessions.reduce(0) { acc, session in
            acc + session.tree.allPanes.reduce(0) { $0 + $1.tabs.filter { $0.terminal.needsConfirmClose }.count }
        }
        let alert = NSAlert()
        alert.messageText = String(localized: "Close Window?")
        alert.informativeText = String(localized: "There are \(busyCount) running process(es) in this window. Closing it will end them.")
        alert.addButton(withTitle: String(localized: "Close"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.alertStyle = .warning
        let result = alert.runModal()
        return result == .alertFirstButtonReturn
    }

    /// Tears down the window's resources after the window has closed:
    ///   1. Clean up bell-feed state for all tabs in the window.
    ///   2. Release every terminal view in the window's host.
    ///   3. Release the host itself.
    ///   4. Remove the window from the NSWindow ↔ WindowID registry (this
    ///      also triggers `terminateIfLastContentWindowGone` on the store).
    ///   5. Remove the `WindowRuntime` from `AppStateStore.windows`.
    func windowWillClose(_ notification: Notification) {
        logger.info("windowWillClose windowID=\(self.windowID.value, privacy: .public)")
        let runtime = store.windowRuntime(for: self.windowID)
        // 1. Bell-feed cleanup: collect all tab IDs in the window.
        let allTabIDs = Set(runtime.sessions.flatMap { session in
            session.tree.allPanes.flatMap { $0.tabs.map(\.id) }
        })
        if !allTabIDs.isEmpty {
            runtime.cleanUpBellState(forTabIDs: allTabIDs)
        }
        // 2. Release terminal views (the only sanctioned removeFromSuperview path).
        for tabID in allTabIDs {
            TerminalHostStore.shared.releaseTerminalView(forTabID: tabID)
        }
        // 3. Release the host (gated: waits until all tab views are gone).
        TerminalHostStore.shared.releaseHost(forWindowID: windowID)
        // 4. Unregister the NSWindow from the store (triggers termination check).
        if let nsWindow = notification.object as? NSWindow {
            store.unregisterNSWindow(nsWindow)
        }
        // 5. Remove the WindowRuntime from the windows list.
        store.removeWindow(id: windowID)
    }

    /// Pauses/resumes rendering for every surface in this window when the
    /// window itself becomes fully occluded (covered by another window),
    /// minimized, or hidden (Cmd-H) — none of which flip any Tab/Pane's own
    /// `isHidden`/placement state, so the per-Tab occlusion signalling in
    /// `TerminalHostStore.setPlacement`/`updatePlacements` alone can't see
    /// it. `NSWindow.occlusionState` is the documented AppKit signal for
    /// exactly this (#0288). This runs as a genuine `NSWindowDelegate`
    /// callback outside SwiftUI's update pass — not a write from `body`,
    /// `onChange`, or a representable update — and it writes no `@Observable`
    /// state; it only forwards to `TerminalHostStore`, which re-derives each
    /// tab's effective visibility from its own placement (see that method's
    /// doc comment for why re-showing everything unconditionally would be
    /// wrong).
    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        TerminalHostStore.shared.setWindowOcclusionVisible(
            window.occlusionState.contains(.visible),
            forWindowID: windowID
        )
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
