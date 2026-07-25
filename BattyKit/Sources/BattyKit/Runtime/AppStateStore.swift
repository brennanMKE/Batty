// AppStateStore.swift

import AppKit
import Foundation
import Observation
import OSLog

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "AppStateStore")

@Observable
public final class AppStateStore {
    public static let shared = AppStateStore()

    // MARK: - Global services (cross-window)

    public let bellFeed: BellFeedStore
    public let nameCache: SessionNameCache
    public let themeChrome: ThemeChrome
    /// Set once, at construction. `AppStateStore.shared` is created on the
    /// first access early in app startup (`BattyApp`'s `WindowGroup`
    /// `defaultValue`), so this closely approximates process launch time —
    /// good enough for `statusPayload()`'s `uptimeSeconds` without needing a
    /// kernel-level process-start-time lookup.
    public let launchDate = Date()
    @ObservationIgnored public var notifier: BellNotifying?
    /// Called when `removeSession` empties the window's `sessions`. Nil in
    /// unit tests; the app delegate sets this to terminate the process.
    /// Forwarded to `windows[0].onAllSessionsClosed`.
    /// Called when `removeSession` empties the **first** window's `sessions`.
    /// Forwarded to `windows[0].onAllSessionsClosed` for backward compat with
    /// the single-window era. `#0239`: each window now has its own
    /// `onAllSessionsClosed` closure that closes the window instead of
    /// terminating the app; `BattyApp` wires this shim to the app-level
    /// hook that quits when the last content window has been closed.
    @ObservationIgnored public var onAllSessionsClosed: (() -> Void)? {
        get { windows[0].onAllSessionsClosed }
        set { windows[0].onAllSessionsClosed = newValue }
    }
    /// AI fallback for session auto-naming (#0231). Nil disables the AI
    /// step entirely — the deterministic chain behaves exactly as before.
    /// The app delegate wires `FoundationModelsNameSuggester.makeIfAvailable()`.
    @ObservationIgnored public var nameSuggester: SessionNameSuggesting?
    /// AI notification summarizer (#0246). Nil disables summarization. The
    /// app delegate wires `FoundationModelsNotificationSummarizer.makeIfAvailable()`.
    @ObservationIgnored public var notificationSummarizer: NotificationSummarizing?
    /// Called by `BattyShortcuts` (the NSEvent-monitor path) to open a new
    /// content window. The app delegate wires this to SwiftUI's captured
    /// `OpenWindowAction` — same wiring style as `onAllSessionsClosed`. Nil
    /// in unit tests and before the delegate sets it.
    @ObservationIgnored public var openWindowAction: (() -> Void)?
    /// NSWindow → WindowID mapping. Populated from each window's view tree
    /// (via `WindowIDRegistrar`) so `BattyShortcuts` can identify the key
    /// window's `WindowRuntime` without relying on window-title heuristics.
    /// `@ObservationIgnored` — populated from AppKit callbacks, not from
    /// SwiftUI-update code (the #0229 hazard class).
    @ObservationIgnored private var nsWindowMap: [ObjectIdentifier: WindowID] = [:]
    /// One in-flight AI naming request per session, keyed by session id and
    /// tagged with the cwd it was issued for so a repeat report of the same
    /// cwd doesn't cancel-and-restart the request.
    @ObservationIgnored var nameSuggestionTasks: [UUID: (path: String, task: Task<Void, Never>)] = [:]
    /// In-memory memo of path -> suggestion (or nil for NONE/junk/error) so
    /// repeated cds into the same folder don't re-prompt the model. Distinct
    /// from `SessionNameCache` and deliberately never persisted — AI names
    /// are ephemeral and must re-resolve on every launch.
    @ObservationIgnored private var nameSuggestionMemo: [String: String?] = [:]
    private static let nameSuggestionMemoCap = 256
    /// One in-flight AI naming request per Tab, keyed by tab id (#0260).
    /// Shares `nameSuggestionMemo` with session naming — both are keyed
    /// purely by cwd, so a directory named for one session's anchor tab
    /// answers every other tab's request for that same directory without
    /// a second on-device model call.
    @ObservationIgnored var tabNameSuggestionTasks: [UUID: (path: String, task: Task<Void, Never>)] = [:]

    // MARK: - Per-window state

    /// All content windows. One element in the current (phase 2) single-window
    /// era; grows in `#0237` when `New Window` is added.
    @ObservationIgnored public private(set) var windows: [WindowRuntime]

    /// The `WindowID` that `BattyApp`'s `WindowGroup` must use as its
    /// `defaultValue`. Exposing it here lets SwiftUI reuse `windows[0]`
    /// (seeded in `init`) for the first on-screen window rather than creating
    /// a phantom second runtime — the root cause of the #0251 wrong-window bug
    /// where `batty <path>` sessions landed in a runtime SwiftUI never showed.
    public var initialWindowID: WindowID {
        windows[0].id
    }

    /// Returns the `WindowRuntime` for `windowID`, creating one lazily if
    /// it does not yet exist. This is the single path for launch, New Window,
    /// and restoration — all converge here so a new scene and a new runtime
    /// are always created together. The initial window seeded in `init` uses
    /// a known `WindowID`; subsequent windows create a fresh runtime with a
    /// fresh `Session 1` in `$HOME` (no cross-window CWD inheritance).
    public func windowRuntime(for windowID: WindowID) -> WindowRuntime {
        if let existing = windows.first(where: { $0.id == windowID }) {
            return existing
        }
        logger.info("windowRuntime: creating new runtime for windowID=\(windowID.value, privacy: .public)")
        let runtime = WindowRuntime(
            id: windowID,
            sessions: [],
            bellFeed: bellFeed,
            nameCache: nameCache
        )
        // Wire onAllSessionsClosed: closing the last session in a window
        // closes the window itself. RootWindowView maps this to an NSWindow
        // close via the window-close callback set in its view tree. The
        // app terminates separately when the last content window closes
        // (observed in unregisterNSWindow / windowWillClose path).
        // This closure is replaced by `RootWindowView` when the window's
        // view tree is live.
        runtime.onAllSessionsClosed = { [weak runtime] in
            guard let runtime else { return }
            logger.info("onAllSessionsClosed windowID=\(runtime.id.value, privacy: .public): no sessions remaining; requesting window close")
            runtime.closeWindowCallback?()
        }
        windows.append(runtime)
        return runtime
    }

    /// Removes the `WindowRuntime` with the given `id` from `windows`.
    /// Called from the window-close teardown path after all tabs in the
    /// window have been released. Safe to call with an unknown id.
    public func removeWindow(id windowID: WindowID) {
        windows.removeAll { $0.id == windowID }
        logger.info("removeWindow windowID=\(windowID.value, privacy: .public); remaining windows=\(self.windows.count, privacy: .public)")
        // If no registered content windows remain and there was more than
        // one, the app can terminate. With a single-window history the
        // normal path is the onAllSessionsClosed → window close → this
        // remove → terminateIfLastContentWindowGone sequence.
        terminateIfLastContentWindowGone()
    }

    /// Terminates the app when no content windows remain in the registry.
    /// A content window is one registered via `registerNSWindow(_:for:)`.
    /// Help and Settings are not registered and therefore not counted.
    private func terminateIfLastContentWindowGone() {
        // The nsWindowMap only contains live registered windows. When it's
        // empty, all content windows have closed.
        guard nsWindowMap.isEmpty else { return }
        // Guard: if there are still WindowRuntime entries that haven't been
        // removed yet (e.g. due to concurrent teardown), also check windows.
        // A window with sessions still attached is not truly gone.
        guard windows.allSatisfy({ $0.sessions.isEmpty }) else { return }
        logger.info("terminateIfLastContentWindowGone: no content windows remain; terminating")
        nameCache.save()
        NSApp.terminate(nil)
    }

    // MARK: - NSWindow ↔ WindowID registry

    /// The number of registered content windows. Used by `BattyAppDelegate` to
    /// log the window count when handling external URL events — helps diagnose
    /// whether SwiftUI created a spurious second window (#0251 second root cause).
    public var registeredContentWindowCount: Int { nsWindowMap.count }

    // MARK: - XPC status (#0271)

    /// Snapshots current app state for the `status` XPC verb. Tab counting
    /// mirrors `BattyAppDelegate.applicationShouldTerminate`'s `totalTabs`
    /// computation — both walk every window's sessions' `tree.allPanes`.
    public func statusPayload() -> StatusPayload {
        let totalSessions = windows.reduce(0) { $0 + $1.sessions.count }
        let totalTabs = windows.reduce(0) { acc, window in
            acc + window.sessions.flatMap { $0.tree.allPanes }.flatMap { $0.tabs }.count
        }
        return StatusPayload(
            pid: ProcessInfo.processInfo.processIdentifier,
            uptimeSeconds: Date().timeIntervalSince(launchDate),
            windowCount: windows.count,
            sessionCount: totalSessions,
            tabCount: totalTabs
        )
    }

    // MARK: - XPC topology (#0274)

    /// Full topology for the `list` XPC verb: every window, its sessions,
    /// and each session's pane/tab tree. Purely a read over `windows` —
    /// see `TopologyPayloadBuilder.swift` for the walk. Never touches
    /// `selectedSessionID`, `focusedPaneID`, or `activeTabID`, so listing a
    /// background session's topology cannot steal focus or switch the
    /// active session.
    public func topologyPayload() -> TopologyPayload {
        TopologyPayload(
            pid: ProcessInfo.processInfo.processIdentifier,
            windows: windows.map { $0.topologyPayload() }
        )
    }

    /// The slice for a single session, for the `sessionInfo` XPC verb.
    ///
    /// `sessionID` resolves an explicit target across *all* windows (not
    /// just the key window) so a caller in a background session can ask
    /// about itself. `sessionID == nil` falls back to the focused session
    /// — today that means the key window's selected session, or the first
    /// window's selected/first session when no window is key (headless CLI
    /// callers, unit tests). This is the seam #0257's `BATTY_SESSION_ID`
    /// env-var fallback slots into later: the eventual order is `--session`
    /// flag → `BATTY_SESSION_ID` → focused session, of which only the first
    /// and last exist today — the middle branch is #0257's to add, and it
    /// inserts here without changing this method's signature or the reply
    /// schema.
    ///
    /// Returns `nil` when an explicit `sessionID` doesn't resolve to any
    /// session in any window, or when there is no session to fall back to
    /// (no windows, or a window with an empty session list — both
    /// unreachable in practice since every window seeds one session, but
    /// handled rather than force-unwrapped).
    public func sessionInfoPayload(sessionID: UUID? = nil) -> TopologySessionPayload? {
        if let sessionID {
            for window in windows {
                if let session = window.sessions.first(where: { $0.id == sessionID }) {
                    return session.topologyPayload(isActive: window.selectedSessionID == session.id)
                }
            }
            return nil
        }
        guard let window = keyWindowRuntime() ?? windows.first,
              let session = window.selectedSession ?? window.sessions.first
        else {
            return nil
        }
        return session.topologyPayload(isActive: window.selectedSessionID == session.id)
    }

    /// Registers the association between an `NSWindow` and its `WindowID`.
    /// Called from `WindowIDRegistrar` in each window's SwiftUI tree once
    /// the hosting NSWindow is known (from `updateNSView`, deferred off the
    /// update pass). Safe to call multiple times — idempotent per window.
    public func registerNSWindow(_ nsWindow: NSWindow, for windowID: WindowID) {
        let wasNew = nsWindowMap[ObjectIdentifier(nsWindow)] == nil
        nsWindowMap[ObjectIdentifier(nsWindow)] = windowID
        if wasNew {
            logger.debug("registerNSWindow: windowID=\(windowID.value, privacy: .public) registeredContentWindows=\(self.nsWindowMap.count, privacy: .public)")
        }
    }

    /// Removes a closed window from the registry. Called from the window's
    /// NSWindowDelegate `windowWillClose` path after teardown (releasing
    /// tabs, host). Triggers app termination when the last content window
    /// has been closed.
    public func unregisterNSWindow(_ nsWindow: NSWindow) {
        nsWindowMap.removeValue(forKey: ObjectIdentifier(nsWindow))
        logger.info("unregisterNSWindow: registered content windows remaining=\(self.nsWindowMap.count, privacy: .public)")
        terminateIfLastContentWindowGone()
    }

    /// True when `NSApp.keyWindow` is a registered content window (as opposed
    /// to Settings, Help, or panels). Replaces the `mainWindowIsKey()` heuristic
    /// that breaks under `WindowGroup` (identifiers differ per window).
    public func keyWindowIsContentWindow() -> Bool {
        guard let key = NSApplication.shared.keyWindow else { return false }
        return nsWindowMap[ObjectIdentifier(key)] != nil
    }

    /// The `WindowRuntime` for the currently-key content window, if any.
    /// Returns `nil` in unit-test contexts where no window is key.
    /// Used by `BattyShortcuts` to target shortcut dispatch at the right window.
    public func keyWindowRuntime() -> WindowRuntime? {
        guard let key = NSApplication.shared.keyWindow,
              let windowID = nsWindowMap[ObjectIdentifier(key)] else { return nil }
        return windows.first { $0.id == windowID }
    }

    /// The `WindowRuntime` for any registered content window. Used as a
    /// fallback when `keyWindowRuntime()` is nil but the app-level URL handler
    /// needs to target a visible window (e.g. `batty <path>` during the brief
    /// interval between window creation and NSWindow registration). Returns the
    /// key-window runtime when available; falls back to the first registered
    /// window. Returns nil when no window is registered (unit-test context or
    /// before the first content window appears in the view hierarchy).
    public func anyContentWindowRuntime() -> WindowRuntime? {
        if let key = keyWindowRuntime() { return key }
        // Find any registered content window and return its runtime.
        guard let windowID = nsWindowMap.values.first else { return nil }
        return windows.first { $0.id == windowID }
    }

    // MARK: - Init

    public init(
        sessions: [SessionRuntime] = [],
        bellFeed: BellFeedStore = BellFeedStore(),
        nameCache: SessionNameCache = SessionNameCache(),
        notifier: BellNotifying? = nil
    ) {
        self.bellFeed = bellFeed
        self.nameCache = nameCache
        self.notifier = notifier
        self.themeChrome = ThemeChrome(palette: ChromePalette(theme: ThemePreference.activeTheme()))
        let window = WindowRuntime(
            sessions: sessions,
            bellFeed: bellFeed,
            nameCache: nameCache
        )
        // Wire the initial window the same way windowRuntime(for:) wires
        // newly created windows: onAllSessionsClosed → closeWindowCallback.
        // RootWindowView sets closeWindowCallback once the NSWindow is live.
        window.onAllSessionsClosed = { [weak window] in
            guard let window else { return }
            logger.info("onAllSessionsClosed windowID=\(window.id.value, privacy: .public): no sessions remaining; requesting window close")
            window.closeWindowCallback?()
        }
        self.windows = [window]
    }

    // MARK: - Per-window forwarding shims
    //
    // Read-property shims resolve to windows[0]. They are only used from
    // unit-test and UITestDriver contexts where a single window is present;
    // view code uses the per-window `WindowRuntime` from the environment
    // directly. Redefining them to call `keyWindowRuntime()` would break
    // the observation contract — `keyWindowRuntime()` reads
    // `NSApplication.shared.keyWindow`, which is not @Observable, so views
    // reading these computed properties would not re-invalidate when the key
    // window changes (#0248 view-read-path caution).
    //
    // Action shims (below) resolve to the key window so that operations
    // dispatched from NSEvent monitors and other app-global paths target the
    // window the user is interacting with, not always windows[0].

    public var sessions: [SessionRuntime] {
        // windows[0]: read-only shim used only in unit tests and UITestDriver.
        windows[0].sessions
    }

    public var selectedSessionID: UUID? {
        // windows[0]: read-only shim used only in unit tests and UITestDriver.
        get { windows[0].selectedSessionID }
        set { windows[0].selectedSessionID = newValue }
    }

    public var selectedSession: SessionRuntime? {
        // windows[0]: read-only shim used only in unit tests and UITestDriver.
        windows[0].selectedSession
    }

    public var pendingCloseRequest: PendingCloseRequest? {
        // windows[0]: read-only shim used only in unit tests and UITestDriver.
        get { windows[0].pendingCloseRequest }
        set { windows[0].pendingCloseRequest = newValue }
    }

    @discardableResult
    public func addSession(title: String? = nil, workingDirectory: String? = nil) -> SessionRuntime {
        // anyContentWindowRuntime() tries keyWindowRuntime() first (the normal
        // in-app path), then any registered content window (the URL-handler
        // path when the key window hasn't been registered yet, e.g. batty <path>
        // delivered before WindowIDRegistrar fires — #0251). Falls back to
        // windows[0] only in unit-test contexts where no NSWindow is registered
        // and windows[0] is the canonical single runtime.
        let target = anyContentWindowRuntime() ?? windows[0]
        logger.debug("addSession: targeting windowID=\(target.id.value, privacy: .public) totalWindows=\(self.windows.count, privacy: .public) registeredContentWindows=\(self.nsWindowMap.count, privacy: .public) workingDirectory=\(workingDirectory ?? "<nil>", privacy: .public)")
        return target.addSession(title: title, workingDirectory: workingDirectory)
    }

    public func removeSession(id: UUID) {
        cancelNameSuggestion(forSessionID: id)
        // Locate the owning window by session ID — the session may be in any window.
        windowOwning(sessionID: id)?.removeSession(id: id)
    }

    public func renameSession(id: UUID, to newTitle: String) {
        // Locate the owning window by session ID — the session may be in any window.
        windowOwning(sessionID: id)?.renameSession(id: id, to: newTitle)
        // Cancel any in-flight AI naming — an explicit user rename pins
        // the title and must not be overwritten by a late suggestion.
        cancelNameSuggestion(forSessionID: id)
    }

    public func clearSessionName(id: UUID) {
        // Locate the owning window by session ID — the session may be in any window.
        windowOwning(sessionID: id)?.clearSessionName(id: id)
    }

    @discardableResult
    public func duplicateSession(id: UUID) -> SessionRuntime? {
        windowOwning(sessionID: id)?.duplicateSession(id: id)
    }

    public func moveSessions(fromOffsets source: IndexSet, toOffset destination: Int) {
        (keyWindowRuntime() ?? windows[0]).moveSessions(fromOffsets: source, toOffset: destination)
    }

    public func selectSession(at index: Int) {
        (keyWindowRuntime() ?? windows[0]).selectSession(at: index)
    }

    public func closeTab(id tabID: UUID) {
        cancelTabNameSuggestion(forTabID: tabID)
        // Locate the owning window to route the close to the correct
        // WindowRuntime rather than defaulting to windows[0].
        for window in windows {
            if window.locate(tabID: tabID) != nil {
                window.closeTab(id: tabID)
                return
            }
        }
    }

    public func closeFocusedTab() {
        (keyWindowRuntime() ?? windows[0]).closeFocusedTab()
    }

    public func requestCloseTab(id tabID: UUID) {
        // Locate the owning window so the close-confirmation sheet appears
        // on the correct window's session, not always windows[0].
        for window in windows {
            if window.locate(tabID: tabID) != nil {
                window.requestCloseTab(id: tabID)
                return
            }
        }
    }

    public func requestCloseFocusedTab() {
        (keyWindowRuntime() ?? windows[0]).requestCloseFocusedTab()
    }

    public func requestCloseOtherTabs(paneID: UUID, keepingTabID: UUID) {
        // Locate the owning window via pane ID so the operation targets
        // the correct window, not always windows[0].
        for window in windows {
            if window.sessions.contains(where: { $0.tree.allPanes.contains(where: { $0.id == paneID }) }) {
                window.requestCloseOtherTabs(paneID: paneID, keepingTabID: keepingTabID)
                return
            }
        }
    }

    public func confirmPendingClose() {
        (keyWindowRuntime() ?? windows[0]).confirmPendingClose()
    }

    public func cancelPendingClose() {
        (keyWindowRuntime() ?? windows[0]).cancelPendingClose()
    }

    public func focusPane(id: UUID) {
        // Locate the pane's owning window so focus is applied to the
        // correct WindowRuntime rather than always windows[0].
        for window in windows {
            if window.sessions.contains(where: { $0.tree.allPanes.contains(where: { $0.id == id }) }) {
                window.focusPane(id: id)
                return
            }
        }
    }

    /// Hides the pane with `id`, routing to the owning window. No-op when the
    /// pane is the last visible pane in its session (≥1 visible invariant).
    public func hidePane(id: UUID) {
        for window in windows {
            if window.sessions.contains(where: { $0.tree.allPanes.contains(where: { $0.id == id }) }) {
                window.hidePane(id: id)
                return
            }
        }
    }

    /// Un-hides the pane with `id`, routing to the owning window.
    public func showPane(id: UUID) {
        for window in windows {
            if window.sessions.contains(where: { $0.tree.allPanes.contains(where: { $0.id == id }) }) {
                window.showPane(id: id)
                return
            }
        }
    }

    public func focusPane(containingTabID tabID: UUID) {
        // Locate the owning window via tab ID. This is also called from
        // TerminalClickFocusMonitor (event origin), so using the owning
        // window is more precise than keyWindowRuntime() — the clicked
        // terminal's window IS the target, and it may not yet be key
        // (the AppKit makeFirstResponder call comes in the same event).
        for window in windows {
            if window.locate(tabID: tabID) != nil {
                window.focusPane(containingTabID: tabID)
                return
            }
        }
    }

    public func jumpToTab(sessionID: UUID, tabID: UUID) {
        // Locate the owning window by session ID so the jump navigates the
        // correct window's state, not always windows[0].
        windowOwning(sessionID: sessionID)?.jumpToTab(sessionID: sessionID, tabID: tabID)
    }

    /// Marks the active tab in the key content window as seen. Falls back to
    /// `windows[0]` when no key window is identified (unit-test context, or
    /// before the first window registers). In multi-window production, the
    /// `PaneView.onChange(of: pane.activeTabID)` call site uses this to clear
    /// bells for whichever tab just became active in the key window — a tab
    /// in a non-key window gaining a new active tab doesn't clear its bells.
    public func markActiveTabSeen() {
        (keyWindowRuntime() ?? windows[0]).markActiveTabSeen()
    }

    // MARK: - Bell event routing (global — searches across all windows)

    /// Records a BEL tick from the tab with `tabID`. The `windowID` field
    /// on the resulting `BellFeedEntry` is set to the owning window's ID
    /// (retired: the throwaway `UUID()` default from before #0239).
    /// A bell counts as "seen at creation" only when the tab is the active
    /// focused tab AND, when multiple content windows are registered, the
    /// owning window is the key window. In single-window mode (no registered
    /// key window, as in unit tests), `isFocused` alone determines seen-ness.
    public func recordBellTick(forTabID tabID: UUID, surfaceID: UUID = UUID()) {
        let keyWindowID = keyWindowRuntime()?.id
        let multiWindow = keyWindowID != nil
        for window in windows {
            guard let location = window.locate(tabID: tabID) else { continue }
            let delta = location.tab.recordBellTickIfNeeded()
            guard delta > 0 else { return }
            // In multi-window mode: seen requires both in-window focus AND key-window.
            // In single-window / no-key-window mode: isFocused alone (preserves
            // existing single-window test semantics).
            let isOwnerKey = !multiWindow || window.id == keyWindowID
            let effectivelySeen = location.isFocused && isOwnerKey
            for _ in 0..<delta {
                let entry = BellFeedEntry(
                    timestamp: location.tab.lastBellAt ?? Date(),
                    windowID: window.id.value,
                    sessionID: location.session.id,
                    paneID: location.pane.id,
                    tabID: location.tab.id,
                    surfaceID: surfaceID,
                    message: nil,
                    seen: effectivelySeen
                )
                bellFeed.record(entry)
                if !effectivelySeen {
                    window.propagateUnseenForced(at: location)
                }
                postNotification(for: entry, at: location)
                scheduleSummarization(for: entry, tabTitle: location.tab.terminal.title, sessionTitle: location.session.title)
            }
            return
        }
    }

    /// Records a desktop notification event (OSC 9 / OSC 777) from the tab
    /// with `tabID`. `windowID` on the entry carries the real owning window's
    /// ID; in multi-window mode a bell is only "seen at creation" if the owning
    /// window is the key content window and the tab is the focused active tab.
    public func recordDesktopNotification(forTabID tabID: UUID, surfaceID: UUID = UUID()) {
        let keyWindowID = keyWindowRuntime()?.id
        let multiWindow = keyWindowID != nil
        for window in windows {
            guard let location = window.locate(tabID: tabID) else { continue }
            guard location.tab.recordDesktopNotificationIfNeeded() else { return }
            let isOwnerKey = !multiWindow || window.id == keyWindowID
            let effectivelySeen = location.isFocused && isOwnerKey
            let entry = BellFeedEntry(
                timestamp: location.tab.lastBellAt ?? Date(),
                windowID: window.id.value,
                sessionID: location.session.id,
                paneID: location.pane.id,
                tabID: location.tab.id,
                surfaceID: surfaceID,
                message: location.tab.lastBellMessage,
                seen: effectivelySeen
            )
            bellFeed.record(entry)
            if !effectivelySeen {
                window.propagateUnseenForced(at: location)
            }
            postNotification(for: entry, at: location)
            scheduleSummarization(for: entry, tabTitle: location.tab.terminal.title, sessionTitle: location.session.title)
            return
        }
    }

    public func markBellSeen(id: UUID) {
        guard let entry = bellFeed.markSeen(id: id) else { return }
        for window in windows {
            window.decrementUnseen(for: entry)
        }
    }

    public func markAllBellsSeen() {
        let touched = bellFeed.markAllSeen()
        for entry in touched {
            for window in windows {
                window.decrementUnseen(for: entry)
            }
        }
    }

    /// Jumps to the bell feed entry's owning window, makes it key and front
    /// (event-origin call — legal only from a user gesture such as a feed
    /// click or notification tap, never from view-update code), then navigates
    /// to the session/pane/tab. If the entry's window is no longer registered
    /// (the window was closed), the entry is marked seen and the jump no-ops.
    public func jumpToBellEntry(_ entry: BellFeedEntry) {
        // Resolve owning window by matching windowID in the entry.
        let owningWindowID = WindowID(entry.windowID)
        guard let owningWindow = windows.first(where: { $0.id == owningWindowID }) else {
            // Dead-window entry: mark seen and bail.
            logger.info("jumpToBellEntry: owning windowID=\(entry.windowID, privacy: .public) no longer live; marking entry seen")
            markBellSeen(id: entry.id)
            return
        }
        // Bring the owning window forward. makeKeyAndOrderFront is a
        // responder-changing AppKit call: legal here because jumpToBellEntry
        // is only called from feed-click / notification-tap event handlers.
        if let nsWindow = nsWindow(for: owningWindowID) {
            logger.info("jumpToBellEntry: making window \(owningWindowID.value, privacy: .public) key and front")
            nsWindow.makeKeyAndOrderFront(nil)
        }
        owningWindow.jumpToBellEntry(entry)
    }

    /// Returns the `NSWindow` registered for `windowID`, if any.
    public func nsWindow(for windowID: WindowID) -> NSWindow? {
        for (key, id) in nsWindowMap where id == windowID {
            // Reverse-lookup: ObjectIdentifier → NSWindow requires iterating
            // all windows to find the one whose identifier matches. Since the
            // map is small (one entry per content window), this is fine.
            return NSApp.windows.first { ObjectIdentifier($0) == key }
        }
        return nil
    }

    // MARK: - CWD-driven auto-naming (global — AI machinery stays process-wide)

    /// When the anchor tab (first leaf pane's first tab) of a session moves
    /// to a CWD that has a cached name OR matches a project-name rule,
    /// apply the derived name as the session title — but only if the user
    /// hasn't explicitly renamed the session (`titleOverride == true`).
    /// Mirrors the write rule in `renameSession` — only the anchor tab's CWD
    /// drives auto-naming. Cache hits beat project-name extraction so that
    /// a previously-typed rename in this CWD always wins (`#0058` + `#0089`).
    ///
    /// Single-pane sessions also reset to the default `Session N` title
    /// when CWD moves *out* of any project directory (no cache hit, no
    /// project rule match). Multi-pane sessions are skipped entirely —
    /// each pane has its own CWD and picking one would be arbitrary
    /// (`#0213`).
    public func handleWorkingDirectoryChange(forTabID tabID: UUID) {
        // Search across ALL windows — the `sessions` shim resolves to
        // windows[0] only, so using it here would silently skip sessions in
        // every other window (#0248 trigger bug).
        for window in windows {
            for (index, session) in window.sessions.enumerated() {
                let anchorTab = session.tree.root.firstLeafPane.tabs[0]
                guard anchorTab.id == tabID else { continue }
                guard !session.titleOverride else { return }
                guard session.tree.allPanes.count == 1 else { return }
                let cwd = anchorTab.terminal.workingDirectory
                    ?? anchorTab.terminal.configuration.workingDirectory
                guard let cwd, !cwd.isEmpty else { return }
                var resolved = Self.resolveAutoTitle(
                    forCWD: cwd,
                    sessionIndex: index,
                    cache: nameCache,
                    resolver: ProjectNameResolver.shared,
                    nameFromFiles: SettingsPreference.resolvedAutoNameFromFiles()
                )
                if Self.isDefaultSessionTitle(resolved) {
                    // Deterministic chain missed — AI fallback (#0231). A
                    // memoized suggestion stands in for the default directly;
                    // an unknown path kicks off an async request. The settings
                    // toggle (#0233) gates the whole AI step, memo included —
                    // a memoized AI name is still automatic naming.
                    if !SettingsPreference.resolvedAutoNameWithAI() {
                        cancelNameSuggestion(forSessionID: session.id)
                    } else if let memoized = nameSuggestionMemo[cwd] {
                        cancelNameSuggestion(forSessionID: session.id)
                        if let name = memoized {
                            resolved = name
                        }
                    } else {
                        scheduleNameSuggestion(for: session, cwd: cwd)
                    }
                } else {
                    cancelNameSuggestion(forSessionID: session.id)
                }
                guard resolved != session.title else { return }
                logger.info("auto-rename session \(session.title, privacy: .public) -> \(resolved, privacy: .public) for cwd=\(cwd, privacy: .public)")
                session.title = resolved
                return
            }
        }
    }

    private func cancelNameSuggestion(forSessionID sessionID: UUID) {
        guard let inflight = nameSuggestionTasks[sessionID] else { return }
        inflight.task.cancel()
        nameSuggestionTasks[sessionID] = nil
    }

    /// Kicks off the async AI naming request for `cwd`. The deterministic
    /// title has already settled synchronously; the suggestion applies later
    /// only if nothing superseded it (see `applySuggestedName`). The result —
    /// including "no name" — is memoized so repeat visits don't re-prompt.
    private func scheduleNameSuggestion(for session: SessionRuntime, cwd: String) {
        guard let suggester = nameSuggester else { return }
        if let inflight = nameSuggestionTasks[session.id] {
            if inflight.path == cwd { return }
            inflight.task.cancel()
            nameSuggestionTasks[session.id] = nil
        }
        let sessionID = session.id
        let task = Task { [weak self] in
            let raw = await suggester.suggestName(forPath: cwd)
            guard let self, !Task.isCancelled else { return }
            self.nameSuggestionTasks[sessionID] = nil
            let name = raw.flatMap(SessionNameSuggestion.sanitize)
            if self.nameSuggestionMemo.count >= Self.nameSuggestionMemoCap {
                self.nameSuggestionMemo.removeAll(keepingCapacity: true)
            }
            self.nameSuggestionMemo.updateValue(name, forKey: cwd)
            guard let name else { return }
            self.applySuggestedName(name, toSessionID: sessionID, forCWD: cwd)
        }
        nameSuggestionTasks[sessionID] = (path: cwd, task: task)
    }

    /// Applies an AI suggestion only if the world hasn't moved on since the
    /// request was issued: the session still exists, is still single-pane,
    /// the user hasn't renamed it, the anchor cwd is unchanged, and the title
    /// is still the default (no newer resolution superseded the request).
    /// Deliberately never writes `nameCache` and never sets `titleOverride` —
    /// an AI suggestion has the same standing as a rules-derived name: a
    /// later cd re-resolves it and only an explicit user rename is stored.
    private func applySuggestedName(_ name: String, toSessionID sessionID: UUID, forCWD cwd: String) {
        // Search across ALL windows — the `sessions` shim resolves to
        // windows[0] only, so using it here would silently fail for sessions
        // in other windows (#0248).
        let session = windows.lazy.flatMap(\.sessions).first { $0.id == sessionID }
        guard let session else { return }
        guard !session.titleOverride else { return }
        guard session.tree.allPanes.count == 1 else { return }
        let anchorTab = session.tree.root.firstLeafPane.tabs[0]
        let currentCWD = anchorTab.terminal.workingDirectory
            ?? anchorTab.terminal.configuration.workingDirectory
        guard currentCWD == cwd else { return }
        guard Self.isDefaultSessionTitle(session.title) else { return }
        logger.info("AI auto-name session \(session.title, privacy: .public) -> \(name, privacy: .public) for cwd=\(cwd, privacy: .public)")
        session.title = name
    }

    /// Pure decision function for the single-pane CWD-driven auto-naming
    /// chain: cache hit > project-name extraction > default `Session N`.
    /// The default is the only branch that resets a title when the shell
    /// walks *out* of a project directory (`#0213`). Caller is responsible
    /// for the single-pane and `titleOverride` gates, and for resolving
    /// `nameFromFiles` from settings (#0233) — no `UserDefaults` reads here.
    /// Cache hits stay live with `nameFromFiles` off: they record explicit
    /// user renames, not automatic naming.
    static func resolveAutoTitle(
        forCWD cwd: String,
        sessionIndex: Int,
        cache: SessionNameCache,
        resolver: ProjectNameResolver.Resolver,
        nameFromFiles: Bool = true
    ) -> String {
        if let cachedName = cache.lookup(path: cwd) {
            return cachedName
        }
        if nameFromFiles, let derivedName = resolver.resolve(at: cwd) {
            return derivedName
        }
        return String(localized: "Session \(sessionIndex + 1)")
    }

    public static func isDefaultSessionTitle(_ title: String) -> Bool {
        title.wholeMatch(of: defaultSessionTitlePattern) != nil
    }

    private static let defaultSessionTitlePattern: Regex<Substring> = {
        // swiftlint:disable:next force_try
        try! Regex(#"^Session \d+$"#)
    }()

    // MARK: - Tab-level CWD-driven auto-naming (#0260)

    /// Auto-names a single Tab's chip from its working directory, using the
    /// same on-device suggester and per-cwd memo as session auto-naming
    /// (`handleWorkingDirectoryChange(forTabID:)` above). Runs for every
    /// tab in every pane — unlike session naming there is no multi-pane
    /// ambiguity to dodge (#0213): each tab has its own cwd, so each tab
    /// gets its own suggestion. The sidebar pane row (#0259) shows this
    /// same value for a pane's first tab; see `SessionSidebarView.PaneRow`.
    ///
    /// Never overwrites `tab.titleOverride` — an explicit rename pins the
    /// chip until the user resets it, mirroring the session pin.
    public func updateTabAutoName(for tab: TabRuntime) {
        guard tab.titleOverride == nil else {
            cancelTabNameSuggestion(forTabID: tab.id)
            return
        }
        guard SettingsPreference.resolvedAutoNameWithAI() else {
            cancelTabNameSuggestion(forTabID: tab.id)
            return
        }
        let cwd = tab.terminal.workingDirectory ?? tab.terminal.configuration.workingDirectory
        guard let cwd, !cwd.isEmpty else {
            cancelTabNameSuggestion(forTabID: tab.id)
            if tab.aiSuggestedName != nil {
                tab.aiSuggestedName = nil
            }
            return
        }
        if let memoized = nameSuggestionMemo[cwd] {
            cancelTabNameSuggestion(forTabID: tab.id)
            if tab.aiSuggestedName != memoized {
                tab.aiSuggestedName = memoized
            }
            return
        }
        // Not memoized yet — clear any name left over from a prior cwd so
        // the chip falls through to the deterministic chain (project name /
        // prettified path) while the request is in flight, exactly as
        // session naming lets the deterministic title stand until the AI
        // fallback resolves.
        if tab.aiSuggestedName != nil {
            tab.aiSuggestedName = nil
        }
        scheduleTabNameSuggestion(for: tab, cwd: cwd)
    }

    private func cancelTabNameSuggestion(forTabID tabID: UUID) {
        guard let inflight = tabNameSuggestionTasks[tabID] else { return }
        inflight.task.cancel()
        tabNameSuggestionTasks[tabID] = nil
    }

    private func scheduleTabNameSuggestion(for tab: TabRuntime, cwd: String) {
        guard let suggester = nameSuggester else { return }
        let tabID = tab.id
        if let inflight = tabNameSuggestionTasks[tabID] {
            if inflight.path == cwd { return }
            inflight.task.cancel()
            tabNameSuggestionTasks[tabID] = nil
        }
        let task = Task { [weak self, weak tab] in
            let raw = await suggester.suggestName(forPath: cwd)
            guard let self, !Task.isCancelled else { return }
            self.tabNameSuggestionTasks[tabID] = nil
            let name = raw.flatMap(SessionNameSuggestion.sanitize)
            if self.nameSuggestionMemo.count >= Self.nameSuggestionMemoCap {
                self.nameSuggestionMemo.removeAll(keepingCapacity: true)
            }
            self.nameSuggestionMemo.updateValue(name, forKey: cwd)
            guard let name, let tab else { return }
            self.applySuggestedTabName(name, tab: tab, forCWD: cwd)
        }
        tabNameSuggestionTasks[tabID] = (path: cwd, task: task)
    }

    /// Applies an AI suggestion only if the tab hasn't moved on since the
    /// request was issued: no user rename landed, and the cwd is unchanged.
    /// Never writes `titleOverride` — same standing as session naming, a
    /// later `cd` re-resolves it.
    private func applySuggestedTabName(_ name: String, tab: TabRuntime, forCWD cwd: String) {
        guard tab.titleOverride == nil else { return }
        let currentCWD = tab.terminal.workingDirectory ?? tab.terminal.configuration.workingDirectory
        guard currentCWD == cwd else { return }
        tab.aiSuggestedName = name
    }

    // MARK: - Private helpers

    /// Returns the `WindowRuntime` that owns the session with `sessionID`,
    /// searching across all registered windows. Used by the action shims that
    /// route operations by session ID (rename, remove, clear, duplicate) so
    /// they always target the correct window rather than defaulting to windows[0].
    private func windowOwning(sessionID: UUID) -> WindowRuntime? {
        windows.first { $0.sessions.contains(where: { $0.id == sessionID }) }
    }

    private func postNotification(for entry: BellFeedEntry, at location: WindowRuntime.BellLocation) {
        guard let notifier else { return }
        guard !location.session.notificationsMuted else { return }
        let paneIndex = (location.session.tree.allPanes.firstIndex { $0.id == location.pane.id } ?? 0) + 1
        let tabIndex = (location.pane.tabs.firstIndex { $0.id == location.tab.id } ?? 0) + 1
        let tabLabel: String
        if let override = location.tab.titleOverride, !override.isEmpty {
            tabLabel = override
        } else if !location.tab.terminal.title.isEmpty {
            tabLabel = location.tab.terminal.title
        } else {
            tabLabel = String(localized: "Tab \(tabIndex)")
        }
        notifier.post(
            for: entry,
            sessionTitle: location.session.title,
            paneIndex: paneIndex,
            tabLabel: tabLabel
        )
    }

    /// Kicks off async AI summarization for a newly-recorded bell entry.
    /// The entry appears in the feed immediately with today's fallback text;
    /// the summary is written back when the model responds. A nil summarizer,
    /// disabled toggle, or model error leaves the entry unchanged.
    private func scheduleSummarization(for entry: BellFeedEntry, tabTitle: String, sessionTitle: String) {
        guard let summarizer = notificationSummarizer else { return }
        guard SettingsPreference.resolvedSummarizeNotificationsWithAI() else { return }
        let entryID = entry.id
        let message = entry.message
        let tabTitleCopy = tabTitle
        let sessionTitleCopy = sessionTitle
        Task { [weak self] in
            let raw = await summarizer.summarize(
                message: message,
                tabTitle: tabTitleCopy.isEmpty ? nil : tabTitleCopy,
                sessionTitle: sessionTitleCopy.isEmpty ? nil : sessionTitleCopy
            )
            guard let self, !Task.isCancelled else { return }
            guard let summary = raw.flatMap(NotificationSummary.sanitize) else { return }
            self.bellFeed.updateSummary(summary, forEntryID: entryID)
        }
    }
}
