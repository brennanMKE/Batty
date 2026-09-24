// WindowRuntime.swift

import Foundation
import Observation
import OSLog

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "WindowRuntime")

/// Result of `WindowRuntime.closePane(id:refuseIfAppsLastPane:)` /
/// `AppStateStore.closePane(id:)` (#0283).
public enum PaneCloseOutcome: Equatable, Sendable {
    /// The pane was closed: every Tab's Terminal Session in it ended, and
    /// its region left the split tree with the sibling subtree taking over
    /// the space.
    case closed
    /// No pane with that id exists in any window.
    case unknownPane
    /// At least one Tab in the pane has a process libghostty reports as
    /// still needing confirmation to close (`TerminalViewState
    /// .needsConfirmClose`). There is no UI to confirm in over XPC, so the
    /// close is refused outright rather than silently bypassing the guard
    /// the user configured or force-killing the process unasked.
    /// Unreachable against a real process today — the polyfill hard-codes
    /// the signal to `false` — but unit-testable via
    /// `TabRuntime.needsConfirmCloseOverride` (#0398).
    case needsConfirmation
    /// Closing would leave the app with zero sessions across every
    /// window — the exact condition that walks into #0217's silent-quit
    /// cascade (`onAllSessionsClosed` → window close → app termination,
    /// with no confirmation dialog since `applicationShouldTerminate` finds
    /// no tabs left by the time it runs). Refused so an unattended XPC
    /// caller cannot chain a single command into quitting Batty.
    case refusedLastPane
}

/// Per-window state and behavior. One instance per content window;
/// with a single window, `AppStateStore.shared.windows[0]` is the
/// unique instance. Follows the `SessionRuntime`/`PaneRuntime`/`TabRuntime`
/// naming family.
///
/// `AppStateStore` keeps the per-instance strong reference and exposes
/// `windows: [WindowRuntime]` plus forwarding shims so existing call
/// sites continue to resolve to the single runtime in this phase (#0235).
@Observable
public final class WindowRuntime {
    public let id: WindowID
    public private(set) var sessions: [SessionRuntime]
    /// The model-level choke point for the non-selected-Session visibility
    /// fact `docs/pane-view-lifecycle.md` §5 left as an open wiring question
    /// (#0349): every write — `setSelectedSession(id:)` (sidebar click, and
    /// the CLI focus verbs), `selectSession(at:)` (Cmd-1..9),
    /// `addSession`/`removeSession`/`duplicateSession`, and
    /// `jumpToTab`/`jumpToBellEntry` — funnels through this one property,
    /// so `didSet` is the single place that delivers `setVisible` to the
    /// two Sessions a selection change crosses, rather than each call site
    /// re-deriving it. Not fired for the initial assignment inside `init`
    /// (Swift suppresses observers for a property's first set within its
    /// own type's initializer) — harmless, since `PaneRuntime.init` already
    /// starts a freshly-constructed Session's panes in the right phase
    /// for the single-Session-at-construction-time production paths
    /// (`addSession`, a new window's first Session). The multi-Session
    /// `init(sessions:)` overload has no production call site (every
    /// production `WindowRuntime` is created with `sessions: []`); test
    /// code that constructs one directly with several non-empty Sessions
    /// does not get this sweep for Sessions beyond the first.
    public var selectedSessionID: UUID? {
        didSet {
            guard oldValue != selectedSessionID else { return }
            applySelectionVisibility(deselecting: oldValue, selecting: selectedSessionID)
        }
    }
    public var pendingCloseRequest: PendingCloseRequest?
    /// Called when `removeSession` empties `sessions`. Set by `AppStateStore`
    /// on new runtimes to close the owning window; `RootWindowView` replaces
    /// it with a closure that calls `NSWindow.performClose` on the live window.
    @ObservationIgnored public var onAllSessionsClosed: (() -> Void)?
    /// Called by `onAllSessionsClosed` to close the owning NSWindow.
    /// Set by `RootWindowView` once the NSWindow is known. The level of
    /// indirection (closure vs. direct NSWindow reference) keeps NSWindow
    /// out of the pure-model layer. `AppStateStore.windowRuntime(for:)`
    /// seeds a no-op default that logs a warning if the window hasn't
    /// set it yet — possible on very early session close before the view
    /// tree is live.
    @ObservationIgnored public var closeWindowCallback: (() -> Void)?

    // Injected from AppStateStore — global services shared across windows.
    @ObservationIgnored let bellFeed: BellFeedStore
    @ObservationIgnored let nameCache: SessionNameCache

    /// Palette index most recently handed out by `nextColorIndex()`, so
    /// consecutive Session creations keep walking `SessionColor`'s palette
    /// in order even after a closure frees up an earlier index (#0335). Not
    /// a Session's color — Sessions never lose their assigned index; this
    /// is purely the assigner's own cursor.
    @ObservationIgnored private var lastAssignedColorIndex = SessionColor.allCases.count - 1

    public init(
        id: WindowID = WindowID(),
        sessions: [SessionRuntime] = [],
        bellFeed: BellFeedStore,
        nameCache: SessionNameCache
    ) {
        self.id = id
        self.bellFeed = bellFeed
        self.nameCache = nameCache
        if sessions.isEmpty {
            // First-ever Session in an empty window: least-used-with-no-
            // usage always resolves to palette index 0, the same result
            // `nextColorIndex()` would compute from a fresh cursor — spelled
            // out directly here because `self.sessions` can't be read by
            // an instance method until phase-1 init finishes.
            let initial = SessionRuntime(title: String(localized: "Session 1"), colorIndex: 0)
            self.sessions = [initial]
            self.selectedSessionID = initial.id
            self.lastAssignedColorIndex = 0
        } else {
            self.sessions = sessions
            self.selectedSessionID = sessions.first?.id
        }
    }

    /// Least-used round-robin palette assignment, scoped to this window
    /// (#0335). Picks the palette index used by the fewest live Sessions;
    /// ties break by palette order starting just after the last index this
    /// assigner handed out, so a run of creations spreads across the
    /// palette instead of piling onto whatever index a recent closure freed.
    private func nextColorIndex() -> Int {
        let paletteCount = SessionColor.allCases.count
        var counts = [Int](repeating: 0, count: paletteCount)
        for session in sessions where counts.indices.contains(session.colorIndex) {
            counts[session.colorIndex] += 1
        }
        let minCount = counts.min() ?? 0
        var chosen = (lastAssignedColorIndex + 1) % paletteCount
        for step in 0..<paletteCount {
            let candidate = (lastAssignedColorIndex + 1 + step) % paletteCount
            if counts[candidate] == minCount {
                chosen = candidate
                break
            }
        }
        lastAssignedColorIndex = chosen
        return chosen
    }

    /// Explicit per-Session color choice (#0336), routed here rather than
    /// as a direct `SessionRuntime` write because the automatic assigner's
    /// bookkeeping is Window-scoped — `nextColorIndex()`'s usage tally
    /// already counts every live Session's `colorIndex` regardless of
    /// `colorOverride`, so an explicit pick composes with the assigner for
    /// free and needs no change there. No-op for an out-of-range index or a
    /// redundant write, per the idempotence rule (`setSelectedSession`'s
    /// pattern) — `@Observable` notifies on every write, equal values
    /// included.
    public func setSessionColor(id: UUID, to colorIndex: Int) {
        guard SessionColor.allCases.indices.contains(colorIndex) else {
            logger.warning("setSessionColor: rejected out-of-range colorIndex=\(colorIndex, privacy: .public)")
            return
        }
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        guard session.colorIndex != colorIndex || !session.colorOverride else { return }
        session.colorIndex = colorIndex
        session.colorOverride = true
    }

    /// Returns a Session to automatic assigner control (#0336). Leaves
    /// `colorIndex` untouched — the Session keeps the color it currently
    /// shows rather than jumping to a freshly re-derived one the instant
    /// the user resets it (#0336's Open questions). No-op if the Session
    /// isn't explicitly colored.
    public func resetSessionColor(id: UUID) {
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        guard session.colorOverride else { return }
        session.colorOverride = false
    }

    public var selectedSession: SessionRuntime? {
        guard let id = selectedSessionID else { return nil }
        return sessions.first { $0.id == id }
    }

    // MARK: - Session CRUD

    @discardableResult
    public func addSession(title: String? = nil, workingDirectory: String? = nil) -> SessionRuntime {
        // `focusedTerminalPane`, not `focusedPaneAnyKind` (#0332 B3): this
        // reads `.activeTab` to inherit its cwd, and a non-terminal pane's
        // placeholder Tab never has a real `workingDirectory` to inherit
        // anyway (`PaneRuntime.kind`'s doc comment) — resolving through the
        // kind-aware accessor makes "nothing to inherit" explicit instead
        // of an accident of the placeholder never being spawned.
        let sourceTab = selectedSession?.focusedTerminalPane?.activeTab
        // An explicit workingDirectory overrides CWD inheritance.
        let effectiveCWD: String?
        if let explicit = workingDirectory, !explicit.isEmpty {
            effectiveCWD = explicit
        } else {
            effectiveCWD = sourceTab?.terminal.workingDirectory
                ?? sourceTab?.terminal.configuration.workingDirectory
        }
        let cachedName: String? = {
            guard title == nil, let cwd = effectiveCWD, !cwd.isEmpty else { return nil }
            return nameCache.lookup(path: cwd)
        }()
        let resolvedTitle = title ?? cachedName ?? String(localized: "Session \(sessions.count + 1)")
        let firstPane = PaneRuntime(tabs: [TabRuntime(workingDirectory: effectiveCWD)])
        let tree = SplitTree(root: .leaf(firstPane))
        let session = SessionRuntime(title: resolvedTitle, tree: tree, colorIndex: nextColorIndex())
        if title != nil {
            session.titleOverride = true
        }
        sessions.append(session)
        selectedSessionID = session.id
        return session
    }

    /// `fromCli` marks the emitted `session_destroyed` event as XPC-driven
    /// (#0396), matching `focusSessionForXPC`/`focusPaneForXPC`/
    /// `focusTabForXPC`'s `fromCli: true`. Per caller: Sidebar close (via
    /// `requestRemoveSession`) and the `closeTab` cascade keep the default
    /// `false` — no XPC verb reaches `closeTab` (`XPCVerb` has no tab-close
    /// verb), so every route into it (menu ⌘W, the NSEvent monitor, the
    /// Command Palette, the tab-chip close button, the confirmation
    /// dialog, and libghostty's `onClose`) is GUI or PTY. The `closePane`
    /// cascade is **not** exclusively GUI-origin the way `closeTab`'s is:
    /// `WindowRuntime.closePane` has two production entry points —
    /// `closeNonTerminalPane` (⌘W on a non-terminal pane and #0378's
    /// non-terminal Pane close button, both GUI-origin) and
    /// `AppStateStore.closePane(id:)`, the XPC `batty pane close` verb (see
    /// that method's own doc comment) — so `closePane` threads its own
    /// `fromCli` through from its caller rather than hard-coding either
    /// value.
    public func removeSession(id: UUID, fromCli: Bool = false) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else {
            logger.warning("removeSession id=\(id, privacy: .public) not found in window \(self.id.value, privacy: .public)")
            return
        }
        let session = sessions[index]
        logger.info("removeSession id=\(id, privacy: .public) title='\(session.title, privacy: .public)' sessionsAfter=\(self.sessions.count - 1)")
        // #0145/#0396: notify the active XPC watchers before mutating — the
        // single choke point every removal path funnels through (Sidebar's
        // "Close", the closeTab/closePane cascades when their tree empties,
        // and AppStateStore.removeSession/closeSessionForXPC), so
        // session_destroyed now fires regardless of which hand destroyed
        // the Session. Placed after the existence guard above rather than
        // before it (unlike the emission this replaces, at the old
        // AppStateStore.removeSession) so an unknown id never emits a
        // phantom event for a Session that was never destroyed.
        let sessionEvent = WatchEventPayload(type: "session_destroyed", sessionID: id, fromCli: fromCli)
        AppEventWatcher.shared.send(eventType: sessionEvent.type, payload: sessionEvent)
        let tabIDsToClear = Set(session.tree.allPanes.flatMap { $0.tabs.map(\.id) })
        cleanUpBellState(forTabIDs: tabIDsToClear)
        for tabID in tabIDsToClear {
            TerminalHostStore.shared.releaseTerminalView(forTabID: tabID)
        }
        // Review round 1 (#0314): this path never funneled through
        // closePane, so a non-terminal pane's content never got torn down
        // when its Session closed directly (the sidebar's "close session"
        // control, AppStateStore.removeSession) — `docs/pane-view-lifecycle.md`
        // §5's "closePane is the single choke point every close path
        // funnels through" is corrected below; it wasn't true of this one.
        tearDownNonTerminalContent(in: session.tree.allPanes)
        sessions.remove(at: index)
        if selectedSessionID == id {
            let newIndex = max(0, index - 1)
            selectedSessionID = sessions.indices.contains(newIndex) ? sessions[newIndex].id : nil
        }
        if sessions.isEmpty {
            logger.info("removeSession all sessions gone; invoking onAllSessionsClosed")
            onAllSessionsClosed?()
        }
    }

    /// Confirmation-gated entry point for closing a whole Session (#0396) —
    /// the Sidebar's "Close" control's counterpart to `requestCloseTab`/
    /// `requestCloseOtherTabs`. Sweeps every Tab across every Pane in the
    /// Session for `needsConfirmClose`; if any are found, raises the same
    /// `PendingCloseRequest` dialog those two use rather than mutating
    /// immediately, so closing a Session from the Sidebar is never *more*
    /// destructive than closing one of its Tabs with ⌘W. No-op (with its
    /// own warning log) if `id` isn't a live Session.
    ///
    /// `removeSession(id:)` itself stays unconditional — the `closeTab`/
    /// `closePane` cascades that call it already swept their own tabs/panes
    /// before the tree emptied (by which point there is nothing left to
    /// find here), and the XPC verb (`AppStateStore.closeSessionForXPC`)
    /// has its own refusal shape with no UI to prompt through.
    public func requestRemoveSession(id: UUID) {
        guard let session = sessions.first(where: { $0.id == id }) else {
            logger.warning("requestRemoveSession id=\(id, privacy: .public) not found in window \(self.id.value, privacy: .public)")
            return
        }
        let busy = session.tree.allPanes.flatMap(\.tabs).filter { $0.needsConfirmClose }
        guard !busy.isEmpty else {
            removeSession(id: id)
            return
        }
        let busyCount = busy.count
        let title = session.title
        let message = busyCount == 1
            ? String(localized: "\(title) has a tab that is still running a process. Closing it will end that process.")
            : String(localized: "\(title) has \(busyCount) tabs that are still running processes. Closing it will end them.")
        pendingCloseRequest = PendingCloseRequest(kind: .session(sessionID: id), message: message)
    }

    public func renameSession(id: UUID, to newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        session.title = trimmed
        session.titleOverride = true
        guard !AppStateStore.isDefaultSessionTitle(trimmed) else { return }
        let firstTab = session.tree.root.firstLeafPane.tabs[0]
        let cwd = firstTab.terminal.workingDirectory
            ?? firstTab.terminal.configuration.workingDirectory
        guard let cwd, !cwd.isEmpty else { return }
        nameCache.record(path: cwd, name: trimmed)
    }

    public func clearSessionName(id: UUID) {
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        session.titleOverride = false
        let anchorTab = session.tree.root.firstLeafPane.tabs[0]
        let cwd = anchorTab.terminal.workingDirectory
            ?? anchorTab.terminal.configuration.workingDirectory
        guard let cwd, !cwd.isEmpty else { return }
        nameCache.removeName(forPath: cwd)
        if let derivedName = ProjectNameResolver.shared.resolve(at: cwd) {
            session.title = derivedName
            return
        }
        let basename = URL(fileURLWithPath: cwd).lastPathComponent
        if !basename.isEmpty {
            session.title = basename
        }
    }

    @discardableResult
    public func duplicateSession(id: UUID) -> SessionRuntime? {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return nil }
        let source = sessions[index]
        // Fresh color, not the source's — the source is still in `sessions`
        // while `nextColorIndex()` tallies usage, so it naturally counts as
        // "in use" and the least-used pick tends to land elsewhere.
        let copy = SessionRuntime(title: String(localized: "\(source.title) Copy"), colorIndex: nextColorIndex())
        sessions.insert(copy, at: index + 1)
        selectedSessionID = copy.id
        return copy
    }

    public func moveSessions(fromOffsets source: IndexSet, toOffset destination: Int) {
        sessions.move(fromOffsets: source, toOffset: destination)
    }

    public func selectSession(at index: Int) {
        guard sessions.indices.contains(index) else { return }
        selectedSessionID = sessions[index].id
    }

    /// Single entry point for sidebar `List` selection writes. macOS `List`
    /// derives an implicit selection value from each row's ForEach identity
    /// even without an explicit `.tag()`, so pane rows can offer pane ids and
    /// an empty-area click offers nil (#0258). Both are rejected: while
    /// sessions exist, some session is always selected. Idempotent — an
    /// equal-value write on an @Observable still notifies (#0229).
    public func setSelectedSession(id: UUID?) {
        guard let id, sessions.contains(where: { $0.id == id }) else {
            logger.notice("setSelectedSession: rejected id=\(id?.uuidString ?? "nil", privacy: .public) — not a session in this window")
            return
        }
        if selectedSessionID != id {
            selectedSessionID = id
        }
    }

    // MARK: - Tab close cascade

    public func closeTab(id tabID: UUID) {
        let totalTabs = sessions.flatMap { $0.tree.allPanes }.flatMap { $0.tabs }.count
        logger.info("closeTab tab=\(tabID, privacy: .public) sessions=\(self.sessions.count) totalTabs=\(totalTabs)")
        for session in sessions {
            for pane in session.tree.allPanes where pane.tabs.contains(where: { $0.id == tabID }) {
                cleanUpBellState(forTabIDs: [tabID])
                pane.removeTab(id: tabID)
                logger.info("closeTab removed tab=\(tabID, privacy: .public) pane=\(pane.id, privacy: .public) session=\(session.id, privacy: .public) paneTabsRemaining=\(pane.tabs.count)")
                if pane.tabs.isEmpty {
                    logger.info("closeTab pane=\(pane.id, privacy: .public) empty; removing from tree")
                    // Review round 1 (#0314): the pane is about to leave the
                    // tree without ever going through closePane — tear down
                    // its non-terminal content here directly, the same
                    // correction applied to removeSession above.
                    tearDownNonTerminalContent(in: [pane])
                    let treeEmptied = session.tree.removePane(id: pane.id)
                    if treeEmptied {
                        logger.info("closeTab tree empty for session=\(session.id, privacy: .public); removing session")
                        removeSession(id: session.id)
                    } else {
                        // #0337: this cascade had no post-remove focus fixup
                        // at all before — `closePane`'s hidden-pane backstop
                        // (below) must hold here too, not only on the
                        // `closePane` branch.
                        resolveHiddenFocusFallback(in: session)
                    }
                }
                return
            }
        }
        logger.warning("closeTab tab=\(tabID, privacy: .public) not found in any session")
    }

    /// For a `.terminal` focused pane, closes its active Tab (kind-gated
    /// through `SessionRuntime.focusedTerminalPane`, #0315 review round 2,
    /// finding 2 — never the structural placeholder tab of a non-terminal
    /// pane). For a non-terminal focused pane there is no Tab bar and
    /// nothing for ⌘W to act on at the Tab level, so this closes the
    /// **Pane** itself instead (#0334) — otherwise the #0315 Tab-command
    /// gating left non-terminal panes with no keyboard/menu route to being
    /// closed at all. `refuseIfAppsLastPane: false` matches this path's
    /// existing lack of a cross-window last-pane guard (that guard exists
    /// only for the unattended XPC verb — see `AppStateStore
    /// .closePane(id:)`'s doc comment). Centralizing both branches here
    /// protects every caller (menu bar, `BattyShortcuts`' NSEvent monitor,
    /// Command Palette) in one place.
    public func closeFocusedTab() {
        guard let session = selectedSession else { return }
        if let pane = session.focusedTerminalPane {
            closeTab(id: pane.activeTabID)
        } else {
            closeNonTerminalPane(session.focusedPaneAnyKind.id)
        }
    }

    /// Title for the "Close Tab" menu item (`BattyCommands`' Tab menu),
    /// reflecting what `closeFocusedTab()`/`requestCloseFocusedTab()`
    /// actually do for the current focus (#0334) — "Close Tab" for a
    /// `.terminal` pane (unchanged), "Close Pane" otherwise, so the menu
    /// item never claims to close a Tab when it's about to close the
    /// Pane. Falls back to "Close Tab" when there's no selected session,
    /// matching the item's disabled state in that case.
    public var closeFocusedItemTitle: String {
        guard let session = selectedSession, session.focusedPaneAnyKind.kind != .terminal else {
            return String(localized: "Close Tab")
        }
        return String(localized: "Close Pane")
    }

    public func requestCloseTab(id tabID: UUID) {
        guard let location = locate(tabID: tabID) else { return }
        if location.tab.needsConfirmClose {
            let label = Self.runningLabel(for: location.tab)
            pendingCloseRequest = PendingCloseRequest(
                kind: .singleTab(tabID: tabID),
                message: String(localized: "\(label) is still running. Closing this tab will end it.")
            )
        } else {
            closeTab(id: tabID)
        }
    }

    /// Same kind-gate as `closeFocusedTab()`, for the confirmation-routed
    /// close path (#0315 review round 2, finding 2) — this is the method
    /// the menu bar's "Close Tab"/"Close Pane" and the Command Palette's
    /// `.closeTab` both call. A non-terminal focused pane has no live
    /// process to confirm against (`TerminalViewState+Polyfill.swift`
    /// hard-codes `needsConfirmClose` to `false` today, and no non-terminal
    /// pane spawns a PTY regardless), so it routes straight to the same
    /// immediate pane-close `closeFocusedTab()` uses rather than going
    /// through a confirmation dialog with nothing to confirm (#0334).
    public func requestCloseFocusedTab() {
        guard let session = selectedSession else { return }
        if let pane = session.focusedTerminalPane {
            requestCloseTab(id: pane.activeTabID)
        } else {
            closeNonTerminalPane(session.focusedPaneAnyKind.id)
        }
    }

    /// Closes a non-terminal pane with `refuseIfAppsLastPane: false`
    /// (#0334's contract for a GUI-origin close) and `fromCli: false`
    /// (#0396) — shared by `closeFocusedTab()`/`requestCloseFocusedTab()`'s
    /// non-terminal branch (⌘W; `paneID` is always the focused pane there)
    /// and, via `AppStateStore.closeNonTerminalPane(id:)`, the non-terminal
    /// Pane header's close button (#0378's `PaneView.paneCloseButton`;
    /// `paneID` there is the button's own pane, which need not be
    /// focused). `closePane(id:refuseIfAppsLastPane:)` is
    /// `@discardableResult` and can in principle return anything but
    /// `.closed` (`.needsConfirmation` already logs its own refusal
    /// there; `.refusedLastPane` can't happen with `refuseIfAppsLastPane:
    /// false`; `.unknownPane` doesn't log anywhere). Logging any
    /// non-`.closed` outcome here means every caller can never become a
    /// silent no-op, today or if `needsConfirmClose`'s polyfill
    /// (`TerminalViewState+Polyfill.swift`) is ever replaced by the real
    /// thing (#0334 review). Returns the outcome (rather than logging and
    /// discarding it here) so a caller with a user-facing surface — the
    /// close button — can represent a non-`.closed` result instead of
    /// silently swallowing it.
    @discardableResult
    public func closeNonTerminalPane(_ paneID: UUID) -> PaneCloseOutcome {
        let outcome = closePane(id: paneID, refuseIfAppsLastPane: false)
        if outcome != .closed {
            logger.notice("closeNonTerminalPane: pane=\(paneID, privacy: .public) outcome=\(String(describing: outcome), privacy: .public), expected .closed")
        }
        return outcome
    }

    public func requestCloseOtherTabs(paneID: UUID, keepingTabID: UUID) {
        guard let pane = sessions
            .flatMap({ $0.tree.allPanes })
            .first(where: { $0.id == paneID }) else { return }
        let victims = pane.tabs.filter { $0.id != keepingTabID }
        let busy = victims.filter { $0.needsConfirmClose }
        if busy.isEmpty {
            pane.closeOtherTabs(keeping: keepingTabID)
            return
        }
        let busyCount = busy.count
        let totalVictims = victims.count
        let message: String
        if busyCount == totalVictims {
            message = String(localized: "\(busyCount) of these tabs are running processes. Closing them will end those processes.")
        } else {
            message = String(localized: "\(busyCount) of the \(totalVictims) tabs about to close are running processes.")
        }
        pendingCloseRequest = PendingCloseRequest(
            kind: .otherTabs(paneID: paneID, keepingTabID: keepingTabID),
            message: message
        )
    }

    public func confirmPendingClose() {
        guard let request = pendingCloseRequest else { return }
        pendingCloseRequest = nil
        switch request.kind {
        case .singleTab(let tabID):
            closeTab(id: tabID)
        case .otherTabs(let paneID, let keepingTabID):
            guard let pane = sessions
                .flatMap({ $0.tree.allPanes })
                .first(where: { $0.id == paneID }) else { return }
            pane.closeOtherTabs(keeping: keepingTabID)
        case .session(let sessionID):
            removeSession(id: sessionID)
        }
    }

    public func cancelPendingClose() {
        pendingCloseRequest = nil
    }

    // MARK: - Pane create (#0331)

    /// Creates a new Pane of `kind`, split off the currently focused Pane in
    /// the selected Session along `direction` — the menu/Command
    /// Palette/shortcut counterpart to #0315's CLI
    /// `batty pane split --view <kind>`. `direction` defaults to
    /// `.horizontal`, matching the CLI's own default
    /// (`PaneSplitCommand.direction`'s "Defaults to horizontal"); callers
    /// that offer both directions (#0331's `splitHorizontal<Kind>` /
    /// `splitVertical<Kind>` action pairs) pass it explicitly, the same
    /// way `splitFocusedPane`/`splitFullDimension` already take an explicit
    /// `direction` for the terminal-only split actions.
    ///
    /// Routes through `SplitTree.splitPane(id:direction:kind:...)` directly
    /// — the same entry point `AppStateStore.splitPane(id:...)` forwards to
    /// for the XPC path (#0303: a menu-created typed pane obeys the same
    /// create machinery as a CLI-created one). Deliberately bypasses
    /// `AppStateStore.splitPane`'s cross-window search and
    /// `AppEventWatcher` notification, matching how the existing GUI split
    /// actions (`splitFocusedPane`/`splitFullDimension`, wired to the
    /// existing Pane menu items and their shortcuts) already behave: a
    /// GUI-driven split has the session in hand and does not emit a watch
    /// event today, typed or not.
    ///
    /// Returns `nil` when there is no selected Session (mirrors the
    /// existing split items' `.disabled(keyWindow?.selectedSession == nil)`
    /// gating) or when the focused Pane has since left the tree — both
    /// defensive, not expected in practice since `focusedPaneID` is always
    /// a Pane the tree itself vouches for.
    ///
    /// `contentFactory` forwards unchanged to `SplitTree.splitPane`'s own
    /// injection point — `nil` (production default) means "resolve the
    /// real conformer for `kind`," which is exactly what a menu/palette
    /// action must do (unlike #0315/#0334's tests, which pass
    /// `{ _ in nil }` to avoid triggering a kind's real `setUp()` — a real
    /// `FSEventStream`, subprocess, or sampling `Task` — as a side effect
    /// of testing unrelated dispatch/gating behavior).
    @discardableResult
    public func createPane(
        kind: PaneContentKind,
        direction: SplitDirection = .horizontal,
        contentFactory: (@MainActor (PaneContentKind) -> (any PaneContentLifecycle)?)? = nil
    ) -> PaneRuntime? {
        guard let tree = selectedSession?.tree else { return nil }
        // `isSessionSelected: true` unconditionally — this always splits
        // `selectedSession`'s own tree (the guard above), so the Session is
        // the selected one by construction, unlike `AppStateStore
        // .splitPane(id:...)`'s XPC path, which can target any Session
        // (#0349).
        return tree.splitPane(id: tree.focusedPaneID, direction: direction, kind: kind, contentFactory: contentFactory, isSessionSelected: true)
    }

    // MARK: - Pane close (#0283)

    /// Ends every Tab's Terminal Session in `paneID` and removes the pane's
    /// region from its owning session's split tree, the sibling subtree
    /// taking over the space — deliberately distinct from `closeTab`, which
    /// ends one tab and removes the pane only when it was that pane's last
    /// tab. Reuses `closeTab`'s teardown primitives (`cleanUpBellState`,
    /// `TerminalHostStore.releaseTerminalView`, `SplitTree.removePane`,
    /// `removeSession`) so surface teardown and bell-state cleanup go
    /// through the same path regardless of entry point.
    ///
    /// `refuseIfAppsLastPane`: the caller (`AppStateStore`) has already
    /// counted every pane across every window and passes `true` only when
    /// `paneID` is the app's last one — see `PaneCloseOutcome.refusedLastPane`.
    /// Trusted as given rather than re-derived here: this window's own
    /// `sessions`/pane counts can't distinguish "the app's last pane" from
    /// "this window's last pane, but a sibling window still has sessions."
    ///
    /// `fromCli` (#0396) forwards to `removeSession(id:fromCli:)` when this
    /// close empties the owning Session's tree. Two production entry
    /// points: `AppStateStore.closePane(id:)` — the XPC `batty pane close`
    /// verb — passes `true`; `closeNonTerminalPane(_:)` (⌘W on a
    /// non-terminal pane, and #0378's non-terminal Pane close button via
    /// `AppStateStore.closeNonTerminalPane(id:)`) is the GUI path and
    /// keeps the default `false`.
    @discardableResult
    public func closePane(id paneID: UUID, refuseIfAppsLastPane: Bool, fromCli: Bool = false) -> PaneCloseOutcome {
        for session in sessions {
            guard let pane = session.tree.allPanes.first(where: { $0.id == paneID }) else { continue }
            if pane.tabs.contains(where: { $0.needsConfirmClose }) {
                logger.notice("closePane: refused pane=\(paneID, privacy: .public) reason=needs-confirmation")
                return .needsConfirmation
            }
            if refuseIfAppsLastPane {
                logger.notice("closePane: refused pane=\(paneID, privacy: .public) reason=last-pane-in-app")
                return .refusedLastPane
            }
            let tabIDs = Set(pane.tabs.map(\.id))
            logger.info("closePane pane=\(paneID, privacy: .public) session=\(session.id, privacy: .public) tabs=\(tabIDs.count, privacy: .public)")
            cleanUpBellState(forTabIDs: tabIDs)
            for tabID in tabIDs {
                TerminalHostStore.shared.releaseTerminalView(forTabID: tabID)
            }
            // A non-terminal pane's own resources (#0303/#0314) are torn
            // down before the pane leaves the tree, synchronously — not a
            // view's onDisappear (`docs/pane-view-lifecycle.md` §5). `nil`
            // for `.terminal` panes and any non-terminal kind without a
            // conformer yet, so this is a no-op there. `closePane` is only
            // one of three pane-removal paths (`removeSession`, `closeTab`
            // are the other two) — see `tearDownNonTerminalContent(in:)`.
            tearDownNonTerminalContent(in: [pane])
            let treeEmptied = session.tree.removePane(id: pane.id)
            if treeEmptied {
                logger.info("closePane tree empty for session=\(session.id, privacy: .public); removing session")
                removeSession(id: session.id, fromCli: fromCli)
            } else {
                resolveHiddenFocusFallback(in: session)
            }
            return .closed
        }
        return .unknownPane
    }

    /// #0256 binds "never leave focus on a hidden pane" — full stop.
    /// `SplitTree.removePane`'s recency-based successor chain (#0337)
    /// already guarantees a *visible* successor whenever any visible pane
    /// survives in the session (history, then the sibling subtree, then a
    /// full-tree scan for any visible leaf — only the absolute last resort,
    /// `firstLeafPaneID`, ignores `isHidden`). So reaching this guard with
    /// `focused.isHidden == true` implies `session.tree.visiblePanes` is
    /// already empty — there is no "move to some other visible pane"
    /// branch to take, only un-hiding `focused` itself so the session isn't
    /// rendered blank (#0256's "≥1 visible pane" rule). Un-hiding is
    /// Runtime-layer work (`TerminalHostStore` placements, content
    /// lifecycle via `showPane`), which is why this lives here rather than
    /// inside `SplitTree` itself.
    ///
    /// Shared by both pane-removal routes that can leave `focusedPaneID`
    /// dangling on a hidden pane — `closePane` above and the `closeTab`
    /// last-Tab cascade, which had no such fixup at all before #0337.
    private func resolveHiddenFocusFallback(in session: SessionRuntime) {
        guard let focused = session.tree.allPanes.first(where: { $0.id == session.tree.focusedPaneID }),
              focused.isHidden else { return }
        logger.notice("resolveHiddenFocusFallback: session=\(session.id, privacy: .public) left with no visible panes; un-hiding focusedPaneID=\(focused.id, privacy: .public)")
        showPane(id: focused.id)
    }

    /// Tears down every non-terminal pane's own content (#0303/#0314) for
    /// each pane in `panes` — the one release step every pane-removal path
    /// must run before (or as) the pane leaves its Session's tree, per
    /// `docs/pane-view-lifecycle.md` §5.
    ///
    /// **Three call sites, not one.** An earlier round of this design
    /// asserted `closePane` was "the single choke point every close path
    /// funnels through" — review round 1 found that false in this tree:
    /// `removeSession` (the sidebar's "close session" control) runs its
    /// own `releaseTerminalView` sweep and never calls `closePane`, and
    /// `closeTab` calls `SplitTree.removePane` directly when a pane's last
    /// Tab closes. Both are production-reachable for a `.systemMetrics`
    /// pane (every `PaneRuntime` holds at least one `TabRuntime`,
    /// `PaneRuntime.init`'s precondition) — closing a Session or the one
    /// tab in a metrics pane through either path left `tearDown()` never
    /// called, so `lifecyclePhase` stayed `.active` and the 1 Hz sampling
    /// `Task` kept running (sweeping ~800 pids, opening the SMC connection
    /// every tick) until `[weak self]` happened to let ARC free the
    /// conformer — exactly the ARC-timing dependence
    /// `PaneContentLifecycle.tearDown()`'s contract forbids relying on.
    /// All three call sites (`closePane`, `removeSession`, `closeTab`) now
    /// funnel through this one helper instead of each re-deriving the
    /// release step.
    ///
    /// Safe to call more than once for the same pane — `tearDown()` is
    /// idempotent (`PaneLifecycleController`'s `.tornDown → .tearDown`
    /// transition is a `.noOp`) — which matters here because `closeTab`
    /// tears its pane down directly and then may call `removeSession`,
    /// whose own sweep no longer finds that pane (already removed from the
    /// tree) but would be harmless even if it did.
    private func tearDownNonTerminalContent(in panes: some Sequence<PaneRuntime>) {
        for pane in panes {
            pane.content?.tearDown()
        }
    }

    /// Tears down every non-terminal pane's content across every Session in
    /// this window — the release step the *window* closing (not any single
    /// pane or Session) must still run. `closePane`/`removeSession`/
    /// `closeTab` all cover a pane or a Session going away individually;
    /// none of them run when the window itself closes with Sessions still
    /// in it (`RootWindowView.windowWillClose`) or when the whole app
    /// quits (`BattyAppDelegate.applicationWillTerminate`, which reaches
    /// every window via `AppStateStore.windows`). Found missing by #0313's
    /// reviewer (that kind's own conformer orphans child processes onto
    /// launchd through the same two gaps) and folded into this round's
    /// shared wiring rather than fixed once per kind.
    public func tearDownAllPaneContent() {
        for session in sessions {
            tearDownNonTerminalContent(in: session.tree.allPanes)
        }
    }

    // MARK: - Pane focus

    /// Marks the pane with `id` as the focused pane in its owning session.
    /// No-op if the pane id doesn't belong to any session in the window.
    /// Does not change the selected session — cross-session focus moves
    /// belong to `jumpToBellEntry` / sidebar selection.
    public func focusPane(id: UUID) {
        for session in sessions {
            if session.tree.allPanes.contains(where: { $0.id == id }) {
                // Idempotent: `focusedPaneID` is on an @Observable, and an
                // equal-value write still fires `withMutation`, re-invalidating
                // every PaneView. Callers legitimately re-assert the current
                // pane (chip selection, repeated clicks in the focused
                // terminal); skipping the equal-value write keeps those from
                // rippling a no-op invalidation through every pane (#0229).
                if session.tree.focusedPaneID != id {
                    logger.debug("focusPane: \(session.tree.focusedPaneID, privacy: .public) -> \(id, privacy: .public)")
                    session.tree.focusedPaneID = id
                }
                return
            }
        }
    }

    /// Focus the pane that owns the tab with `tabID`. The model-side
    /// follow-up to a user click on a terminal: `TerminalClickFocusMonitor`
    /// resolves the clicked `AppTerminalView` to its tab and calls this so
    /// the click is the single declared writer for the AppKit-initiated
    /// focus direction (#0230). No-op if no pane owns the tab.
    public func focusPane(containingTabID tabID: UUID) {
        for session in sessions {
            for pane in session.tree.allPanes where pane.tabs.contains(where: { $0.id == tabID }) {
                focusPane(id: pane.id)
                return
            }
        }
    }

    // MARK: - Session selection visibility

    /// Delivers the non-selected-Session visibility fact (#0349) to every
    /// non-terminal Pane content in the (at most) two Sessions a
    /// `selectedSessionID` write crosses. Called only from that property's
    /// `didSet`, never from a view.
    ///
    /// Looks each id up in `sessions` rather than trusting a caller-held
    /// reference, so a Session already removed from `sessions` (e.g.
    /// `removeSession` removes it, then reassigns `selectedSessionID`
    /// away from it) is silently skipped — its panes' content was already
    /// torn down by `removeSession`, and a `setVisible` call after
    /// `tearDown()` would be a `.rejected` transition
    /// (`PaneLifecycleStateMachine`), not a harmless no-op.
    ///
    /// Only sweeps `!pane.isHidden` panes both directions: a Pane already
    /// hidden via `hidePane` must stay suspended regardless of which
    /// Session is selected (its content was already suspended when it was
    /// hidden, and `showPane` — not this sweep — is what resumes it, and
    /// only when its Session is selected). `setVisible` is idempotent by
    /// contract, so this composes safely with `hidePane`/`showPane` even
    /// where the two paths could otherwise overlap.
    private func applySelectionVisibility(deselecting previousID: UUID?, selecting newID: UUID?) {
        if let previousID, let previous = sessions.first(where: { $0.id == previousID }) {
            for pane in previous.tree.allPanes where !pane.isHidden {
                pane.content?.setVisible(false)
            }
        }
        if let newID, let selected = sessions.first(where: { $0.id == newID }) {
            for pane in selected.tree.allPanes where !pane.isHidden {
                pane.content?.setVisible(true)
            }
        }
    }

    // MARK: - Pane hide / show

    /// Hides the pane with `id`. No-op when the pane is already hidden or when
    /// it is the last visible pane in its session (the ≥1 visible invariant).
    /// Moves focus to the nearest visible sibling when the focused pane is hidden.
    public func hidePane(id: UUID) {
        for session in sessions {
            guard let pane = session.tree.allPanes.first(where: { $0.id == id }) else { continue }
            guard !pane.isHidden else { return }
            guard session.tree.visiblePanes.count > 1 else {
                logger.notice("hidePane: refused id=\(id, privacy: .public) — last visible pane in session")
                return
            }
            // Move focus before hiding so `focusedPaneID` never references a hidden pane.
            if session.tree.focusedPaneID == id {
                if let nextVisible = session.tree.visiblePanes.first(where: { $0.id != id }) {
                    session.tree.focusedPaneID = nextVisible.id
                }
            }
            pane.isHidden = true
            // Expand the session's sidebar pane list so the just-hidden
            // pane's restore control is reachable without hunting (#0258).
            session.isPaneListExpanded = true
            // Hide every terminal view in the pane without releasing it —
            // TerminalPlaceholderView is unmounted while the pane is hidden
            // so its onGeometryChange never fires. Drive TerminalHostStore
            // directly so the AppTerminalView isn't left floating (#0256).
            //
            // Kind-gated (#0315 review round 1, finding 1): a non-terminal
            // pane's tab never mounts a TerminalPlaceholderView and so never
            // registers a `terminalViews` entry — writing a `placements`
            // entry for it here would be a dead entry `releaseTerminalView`
            // can never clean up (its `guard let view = terminalViews
            // .removeValue(...) else { return }` returns before reaching
            // `placements.removeValue`), leaking one `placements[id]` per
            // open→hide→close cycle for the app's lifetime — the #0285
            // unbounded-growth class.
            if pane.kind == .terminal {
                for tab in pane.tabs {
                    TerminalHostStore.shared.setPlacement(
                        TerminalHostStore.Placement(frame: .zero, isVisible: false),
                        forTabID: tab.id
                    )
                }
            }
            // Non-terminal content (#0303/#0314): suspend periodic
            // sampling/watching to zero cost while hidden, driven directly
            // here rather than from a view's unmount for the same reason
            // the terminal placement above is — `docs/pane-view-lifecycle.md`
            // §5. `nil` for `.terminal` panes, so this is a no-op there.
            pane.content?.setVisible(false)
            return
        }
    }

    /// Un-hides the pane with `id`. No-op when the pane is already visible.
    public func showPane(id: UUID) {
        for session in sessions {
            guard let pane = session.tree.allPanes.first(where: { $0.id == id }) else { continue }
            guard pane.isHidden else { return }
            pane.isHidden = false
            // Non-terminal content (#0303/#0314): resume and perform one
            // immediate refresh, matching `docs/pane-view-lifecycle.md`
            // §4's "showing resumes and refreshes" rule. Unlike the
            // terminal path (which relies on `TerminalPlaceholderView`'s
            // remount to re-report a placement, `docs/pane-view-lifecycle.md`
            // §5's noted asymmetry), a non-terminal conformer has no
            // remount to lean on since it isn't torn down and rebuilt by
            // SwiftUI churn — so this call site drives it explicitly rather
            // than leaving it to a view lifecycle event that may not fire.
            // Gated on session selection (#0349): un-hiding a Pane that
            // lives in a non-selected Session must not resume it — only
            // `applySelectionVisibility` (via `selectedSessionID`'s
            // `didSet`) resumes it, once its Session actually becomes
            // selected.
            if session.id == selectedSessionID {
                pane.content?.setVisible(true)
            }
            return
        }
    }

    // MARK: - Navigation

    public func jumpToTab(sessionID: UUID, tabID: UUID) {
        guard let session = sessions.first(where: { $0.id == sessionID }),
              let pane = session.tree.allPanes.first(where: { $0.tabs.contains(where: { $0.id == tabID }) }),
              let oldPane = session.tree.allPanes.first(where: { $0.id == session.tree.focusedPaneID }),
              let oldTab = oldPane.tabs.first(where: { $0.id == oldPane.activeTabID })
        else { return }

        let oldActiveTabTitle = oldTab.titleOverride ?? ""

        // Same #0256 invariant as `jumpToBellEntry`: un-hide the pane before
        // navigating to it, so `focusedPaneID` never references a hidden pane.
        if pane.isHidden {
            showPane(id: pane.id)
        }

        selectedSessionID = session.id
        session.tree.focusedPaneID = pane.id
        pane.activeTabID = tabID

        if let newTab = pane.tabs.first(where: { $0.id == tabID }) {
            let newActiveTabTitle = newTab.titleOverride ?? ""

            // #0145: notify the active XPC watchers of an active-tab change.
            let event = WatchEventPayload(
                type: "active_tab_changed",
                sessionID: session.id,
                targetPaneID: pane.id,
                oldTabTitle: oldActiveTabTitle,
                newTabTitle: newActiveTabTitle
            )
            AppEventWatcher.shared.send(eventType: event.type, payload: event)
        }
    }

    public func jumpToBellEntry(_ entry: BellFeedEntry) {
        guard let session = sessions.first(where: { $0.id == entry.sessionID }),
              let pane = session.tree.allPanes.first(where: { $0.id == entry.paneID }),
              pane.tabs.contains(where: { $0.id == entry.tabID })
        else { return }
        // Un-hide the pane before navigating to it — a bell from a hidden
        // pane's surface must be reachable via the feed (#0256). Route
        // through showPane so any future host-side wiring stays in one place.
        if pane.isHidden {
            showPane(id: pane.id)
        }
        selectedSessionID = session.id
        session.tree.focusedPaneID = pane.id
        pane.activeTabID = entry.tabID
    }

    // MARK: - Bell state (per-window tab-level counters)

    public func markActiveTabSeen() {
        // `focusedTerminalPane`, not `focusedPaneAnyKind` (#0332 B3): this
        // reads `.activeTabID` (and, below, `.tabs`) to clear bell entries
        // for the now-focused tab. A non-terminal pane's placeholder Tab
        // can never carry a real bell entry (only a live surface fires
        // OSC 9 / BEL, and the placeholder never gets one —
        // `PaneRuntime.kind`'s doc comment), so the lookup was already a
        // guaranteed no-op there; resolving through the kind-aware accessor
        // makes that explicit instead of incidental.
        guard let session = selectedSession, let pane = session.focusedTerminalPane else { return }
        let tabID = pane.activeTabID
        let entriesToClear = bellFeed.entries.filter { $0.tabID == tabID && !$0.seen }
        for entry in entriesToClear {
            if let cleared = bellFeed.markSeen(id: entry.id) {
                decrementUnseen(for: cleared)
            }
        }
        guard let tab = pane.tabs.first(where: { $0.id == tabID }) else { return }
        guard tab.unseenBellCount > 0 else { return }
        let residual = tab.unseenBellCount
        tab.unseenBellCount = 0
        pane.unseenBellCount = max(0, pane.unseenBellCount - residual)
        session.unseenBellCount = max(0, session.unseenBellCount - residual)
    }

    // MARK: - Internal helpers (accessible within BattyKit module)

    /// Resolved location of a tab across this window's sessions and panes.
    /// Internal so `AppStateStore`'s bell routing can use it without a separate
    /// lookup.
    struct BellLocation {
        let session: SessionRuntime
        let pane: PaneRuntime
        let tab: TabRuntime
        let isFocused: Bool
    }

    func locate(tabID: UUID) -> BellLocation? {
        for session in sessions {
            for pane in session.tree.allPanes {
                guard let tab = pane.tabs.first(where: { $0.id == tabID }) else { continue }
                let isFocused = session.id == selectedSessionID
                    && session.tree.focusedPaneID == pane.id
                    && pane.activeTabID == tab.id
                return BellLocation(session: session, pane: pane, tab: tab, isFocused: isFocused)
            }
        }
        return nil
    }

    /// Increments unseen counters when `isFocused` is false. Standard path
    /// for within-window unseen propagation.
    func propagateUnseen(at location: BellLocation) {
        guard !location.isFocused else { return }
        location.tab.unseenBellCount += 1
        location.pane.unseenBellCount += 1
        location.session.unseenBellCount += 1
    }

    /// Increments unseen counters regardless of `location.isFocused`.
    /// Called by `AppStateStore` when the entry was determined unseen at
    /// the cross-window level (owning window not key, or tab not focused)
    /// — the `isFocused` guard in `propagateUnseen(at:)` must not run here.
    func propagateUnseenForced(at location: BellLocation) {
        location.tab.unseenBellCount += 1
        location.pane.unseenBellCount += 1
        location.session.unseenBellCount += 1
    }

    /// Decrements by `entry.repeatCount`, not by 1. #0298: a collapsed
    /// entry represents `repeatCount` raw bell occurrences, each of which
    /// called `propagateUnseenForced` once when it arrived — so clearing
    /// the one feed row that absorbed all of them must release all of them,
    /// or the tab/pane/session sidebar counters (`SessionSidebarView`'s
    /// numeric badges) would stay permanently inflated by `repeatCount - 1`
    /// after every mark-seen path that isn't `markActiveTabSeen` (which
    /// already resets straight to 0 as a separate residual-drift guard).
    /// Non-collapsed entries have `repeatCount == 1`, so this is a
    /// straight extension of the pre-#0298 behavior, not a change to it.
    func decrementUnseen(for entry: BellFeedEntry) {
        let amount = max(1, entry.repeatCount)
        for session in sessions where session.id == entry.sessionID {
            session.unseenBellCount = max(0, session.unseenBellCount - amount)
            for pane in session.tree.allPanes where pane.id == entry.paneID {
                pane.unseenBellCount = max(0, pane.unseenBellCount - amount)
                for tab in pane.tabs where tab.id == entry.tabID {
                    tab.unseenBellCount = max(0, tab.unseenBellCount - amount)
                }
            }
        }
    }

    func cleanUpBellState(forTabIDs tabIDs: Set<UUID>) {
        let removed = bellFeed.removeEntries(matchingTabIDs: tabIDs)
        for entry in removed where !entry.seen {
            decrementUnseen(for: entry)
        }
    }

    // MARK: - Private helpers

    private static func runningLabel(for tab: TabRuntime) -> String {
        let title = tab.terminal.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty || title.contains(":") || title.contains("@") {
            return String(localized: "A process")
        }
        return "`\(title)`"
    }
}
