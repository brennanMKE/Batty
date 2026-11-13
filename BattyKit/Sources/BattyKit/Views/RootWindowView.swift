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
    /// Resolved once, by the first init. SwiftUI can rebuild this view for a
    /// window that has just closed; that init computes `nil` and `@State`
    /// discards it, so the closing window keeps its tree and nothing revives
    /// its runtime. The `nil` branch of `body` is reached only if a closed id
    /// is presented to a new scene.
    @State private var windowRuntime: WindowRuntime?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    /// Per-window sidebar visibility. Window restoration is disabled
    /// (`.restorationBehavior(.disabled)` in `BattyApp`), so the value lives
    /// for the life of the process and is not restored across relaunches.
    /// Replaces the single app-wide `SidebarPreference.hiddenKey`
    /// `@AppStorage` property.
    @SceneStorage(SidebarPreference.sceneStorageKey) private var sidebarHidden: Bool = false
    /// One-time migration flag: on first launch after the move to
    /// `@SceneStorage`, seed the per-window value from the legacy global key
    /// so existing single-window users keep their hidden/shown state.
    @AppStorage(SidebarPreference.migratedKey) private var sidebarMigrationDone: Bool = false

    /// `store` is required, not a `.shared`-defaulting optional (#0359's "no
    /// silent default" rule, already applied to `WindowIDRegistrar` in
    /// #0437) — `ContentView` passes `AppStateStore.shared` explicitly, so a
    /// test (or a future multi-store caller) can inject its own store
    /// instead of always touching the process-wide singleton.
    public init(windowID: WindowID, store: AppStateStore) {
        self.windowID = windowID
        _windowRuntime = State(initialValue: store.runtimeForPresentedWindow(windowID))
        _store = State(initialValue: store)
    }

    public var body: some View {
        if let windowRuntime {
            content(windowRuntime)
        }
    }

    @ViewBuilder
    private func content(_ windowRuntime: WindowRuntime) -> some View {
        WindowChromeScope(store: store, windowRuntime: windowRuntime) {
            WindowSeeThroughScope(store: store, windowRuntime: windowRuntime) {
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    SessionSidebarView(store: store, windowRuntime: windowRuntime)
                        .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
                } detail: {
                    SessionDetailView(store: store, windowRuntime: windowRuntime)
                        .environment(\.paneWindowCorners, WindowCorners.detailArea(sidebarHidden: columnVisibility == .detailOnly))
                }
            }
        }
        .environment(\.appStateStore, store)
        .background(WindowIDRegistrar(windowID: windowID, store: store))
        .background(WindowLifecycleController(windowID: windowID, store: store))
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
            // Reads the injected `store`, not `.shared` (#0437 Gotchas) — this
            // deliberately stays on `keyWindowRuntime()`, not the #0439
            // no-target fallback: a keystroke/menu toggle can only mean the
            // window the user is actually looking at right now.
            guard store.keyWindowRuntime()?.id == windowID else { return }
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
}

/// Manages the window lifecycle for a single content window:
///   - wires `WindowRuntime.closeWindowCallback` so a "last session closed"
///     event closes the NSWindow;
///   - installs `WindowDelegate` as the `NSWindowDelegate` to intercept the
///     close button (`windowShouldClose`), track occlusion and full screen,
///     and tear down the window's terminal host and registry entries on
///     close.
///
/// Both are installed synchronously by `WindowLifecycleNSView` when it moves
/// into the window, like `WindowIDRegistrar` (#0437). A `WindowGroup`
/// window gets its content before it is ordered in, so the delegate sees
/// the order-in as its first occlusion transition. `updateNSView` does
/// nothing.
private struct WindowLifecycleController: NSViewRepresentable {
    let windowID: WindowID
    let store: AppStateStore

    func makeNSView(context: Context) -> WindowLifecycleNSView {
        WindowLifecycleNSView(windowID: windowID, store: store)
    }

    func updateNSView(_ nsView: WindowLifecycleNSView, context: Context) {}
}

/// The `NSView` backing `WindowLifecycleController`. Installs the window's
/// delegate and `closeWindowCallback` from `viewDidMoveToWindow`.
///
/// Safe even though `viewDidMoveToWindow` can run while SwiftUI is attaching
/// this view mid-update, for the same reason as `RegistrarNSView`: of what it
/// writes, not when. `NSWindow.delegate` is a plain AppKit property and
/// `closeWindowCallback` is `@ObservationIgnored`, so neither notifies an
/// observer, and neither dirties constraints or changes the first responder.
/// It deliberately reads no occlusion or key state: writing them here could
/// suspend Pane content mid-update. `WindowDelegate` and the app-wide
/// `didBecomeKeyNotification` deliver them as events instead.
///
/// Not `private`: `WindowLifecycleNSViewTests` builds it directly.
final class WindowLifecycleNSView: NSView {
    private let windowID: WindowID
    private let store: AppStateStore
    /// Retained here because `NSWindow.delegate` is weak.
    let windowDelegate: WindowDelegate

    init(windowID: WindowID, store: AppStateStore) {
        self.windowID = windowID
        self.store = store
        self.windowDelegate = WindowDelegate(windowID: windowID, store: store)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        if window.delegate !== windowDelegate {
            window.delegate = windowDelegate
        }
        let id = windowID
        if let runtime = store.existingWindowRuntime(for: id), runtime.closeWindowCallback == nil {
            runtime.closeWindowCallback = { [weak window] in
                logger.info("closeWindowCallback: closing windowID=\(id.value, privacy: .public)")
                window?.performClose(nil)
            }
        }
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
        guard let runtime = store.existingWindowRuntime(for: windowID) else { return true }
        guard QuitConfirmation.windowNeedsConfirmClose(window: runtime, defaults: store.preferences) else {
            return true
        }
        let busyCount = Self.busyTabCount(in: runtime)
        let alert = NSAlert()
        alert.messageText = String(localized: "Close Window?")
        alert.informativeText = String(localized: "There are \(busyCount) running process(es) in this window. Closing it will end them.")
        alert.addButton(withTitle: String(localized: "Close"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.alertStyle = .warning
        let result = alert.runModal()
        return result == .alertFirstButtonReturn
    }

    /// The count `windowShouldClose` shows the user ("There are N running
    /// process(es)..."). Extracted (#0398) so the counting logic is
    /// unit-testable without triggering the modal `NSAlert` above — the same
    /// reason `QuitConfirmation.openTerminalTabCount` was pulled out of
    /// `shouldQuitOrPrompt`.
    static func busyTabCount(in runtime: WindowRuntime) -> Int {
        runtime.sessions.reduce(0) { acc, session in
            acc + session.tree.allPanes.reduce(0) { $0 + $1.tabs.filter { $0.needsConfirmClose }.count }
        }
    }

    /// Tears down the window's resources after the window has closed:
    ///   1. `WindowRuntime.tearDownForWindowClose()`: Bell state and AI work
    ///      for every Tab and Session, non-terminal Pane content, and every
    ///      terminal view in the window's host.
    ///   2. Release the host itself.
    ///   3. Remove the window from the NSWindow ↔ WindowID registry (this
    ///      also triggers `terminateIfLastContentWindowGone` on the store).
    ///   4. Remove the `WindowRuntime` from `AppStateStore.windows`.
    func windowWillClose(_ notification: Notification) {
        logger.info("windowWillClose windowID=\(self.windowID.value, privacy: .public)")
        let runtime = store.existingWindowRuntime(for: self.windowID)
        // 1. Bell rows, AI work, non-terminal Pane content (#0303/#0314) and
        // terminal views (the only sanctioned removeFromSuperview path).
        runtime?.tearDownForWindowClose()
        // 2. Release the host (gated: waits until all tab views are gone).
        TerminalHostStore.shared.releaseHost(forWindowID: windowID)
        // 3. Unregister the NSWindow from the store (triggers termination check).
        if let nsWindow = notification.object as? NSWindow {
            store.unregisterNSWindow(nsWindow)
        }
        // 4. Remove the WindowRuntime from the windows list.
        store.removeWindow(id: windowID)
    }

    /// Pauses/resumes rendering for every surface in this window when the
    /// window itself becomes fully occluded (covered by another window),
    /// minimized, or hidden (Cmd-H) — none of which flip any Tab/Pane's own
    /// `isHidden`/shown state, so the per-Tab occlusion signalling in
    /// `TerminalHostStore.reportFrame`/`setTabShown` alone can't see it. `NSWindow.occlusionState` is the documented AppKit signal for
    /// exactly this (#0288). This runs as a genuine `NSWindowDelegate`
    /// callback outside SwiftUI's update pass — not a write from `body`,
    /// `onChange`, or a representable update — so the writes it causes are
    /// event-origin. It forwards to `TerminalHostStore`, which re-derives each
    /// tab's effective visibility from its view's `isHidden` (see that method's
    /// doc comment for why re-showing everything unconditionally would be
    /// wrong), and to `WindowRuntime.setWindowVisible`, which suspends or
    /// resumes the selected Session's non-terminal Pane content (#0601).
    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        let visible = window.occlusionState.contains(.visible)
        TerminalHostStore.shared.setWindowOcclusionVisible(visible, forWindowID: windowID)
        store.existingWindowRuntime(for: windowID)?.setWindowVisible(visible)
    }

    func windowWillEnterFullScreen(_ notification: Notification) {
        store.windows.first { $0.id == windowID }?.setNativeFullScreen(true)
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        store.windows.first { $0.id == windowID }?.setNativeFullScreen(false)
    }

    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        store.windows.first { $0.id == windowID }?.setNativeFullScreen(false)
    }
}

public enum SidebarPreference {
    /// Legacy app-wide `UserDefaults` key. Read during the one-time migration
    /// in `RootWindowView.applyLegacySidebarMigrationIfNeeded`.
    public static let hiddenKey = "co.sstools.Batty.sidebarHidden"
    /// `@SceneStorage` key for per-window sidebar visibility. Each window
    /// keeps its own value; with window restoration disabled it is not
    /// carried across relaunches.
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
        // When migration is already done, the caller keeps its current
        // @SceneStorage value — nil signals "no override needed."
        guard !migrationDone else { return nil }
        return legacyValue
    }
}

/// The only view that reads `AppStateStore.themeChrome(for:)`, which
/// depends on the window's selected Session, its Theme override and
/// preview, the global Theme names and preview, and the appearance. Those
/// changes re-evaluate only this view; `content` is stored, so it is not
/// rebuilt, and it receives the identical `ThemeChrome` unless the window's
/// Theme actually changes. Nothing writes the chrome.
struct WindowChromeScope<Content: View>: View {
    let store: AppStateStore
    let windowRuntime: WindowRuntime
    let content: Content

    init(store: AppStateStore, windowRuntime: WindowRuntime, @ViewBuilder content: () -> Content) {
        self.store = store
        self.windowRuntime = windowRuntime
        self.content = content()
    }

    var body: some View {
        content.environment(\.themeChrome, store.themeChrome(for: windowRuntime))
    }
}

/// The only view that reads `AppStateStore.isWindowSeeThrough`, which depends
/// on every Pane and Tab in the window. Splits, closes and Tab edits in any
/// Session re-evaluate only this view, not its parent, and `content` is
/// stored, so it is not rebuilt; it receives an equal `Bool` unless the
/// window actually flips.
struct WindowSeeThroughScope<Content: View>: View {
    @Environment(\.themeChrome) private var themeChrome
    let store: AppStateStore
    let windowRuntime: WindowRuntime
    let content: Content

    init(store: AppStateStore, windowRuntime: WindowRuntime, @ViewBuilder content: () -> Content) {
        self.store = store
        self.windowRuntime = windowRuntime
        self.content = content()
    }

    var body: some View {
        let isSeeThrough = store.isWindowSeeThrough(windowRuntime)
        content
            .environment(\.windowIsSeeThrough, isSeeThrough)
            .background(WindowChromeApplier(palette: themeChrome?.palette ?? .default, isSeeThrough: isSeeThrough))
    }
}

/// Themes the host `NSWindow` to match the active palette: paints the
/// window background and makes the title bar transparent so it adopts the
/// themed color uniformly. Reverts to the system default chrome (vibrant
/// title-bar material) when no theme is active. The only writer of the
/// window's `backgroundColor` and `isOpaque` (`WindowSeeThrough.apply`).
private struct WindowChromeApplier: NSViewRepresentable {
    let palette: ChromePalette
    let isSeeThrough: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            WindowSeeThrough.apply(palette: palette, isSeeThrough: isSeeThrough, to: window)
        }
    }
}
