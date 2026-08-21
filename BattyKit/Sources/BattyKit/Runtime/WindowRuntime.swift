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
    public var selectedSessionID: UUID?
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
        let sourceTab = selectedSession?.focusedPane.activeTab
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

    public func removeSession(id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else {
            logger.warning("removeSession id=\(id, privacy: .public) not found in window \(self.id.value, privacy: .public)")
            return
        }
        let session = sessions[index]
        logger.info("removeSession id=\(id, privacy: .public) title='\(session.title, privacy: .public)' sessionsAfter=\(self.sessions.count - 1)")
        let tabIDsToClear = Set(session.tree.allPanes.flatMap { $0.tabs.map(\.id) })
        cleanUpBellState(forTabIDs: tabIDsToClear)
        for tabID in tabIDsToClear {
            TerminalHostStore.shared.releaseTerminalView(forTabID: tabID)
        }
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
                    let treeEmptied = session.tree.removePane(id: pane.id)
                    if treeEmptied {
                        logger.info("closeTab tree empty for session=\(session.id, privacy: .public); removing session")
                        removeSession(id: session.id)
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
            closeFocusedNonTerminalPane(session.focusedPane.id)
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
        guard let session = selectedSession, session.focusedPane.kind != .terminal else {
            return String(localized: "Close Tab")
        }
        return String(localized: "Close Pane")
    }

    public func requestCloseTab(id tabID: UUID) {
        guard let location = locate(tabID: tabID) else { return }
        if location.tab.terminal.needsConfirmClose {
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
            closeFocusedNonTerminalPane(session.focusedPane.id)
        }
    }

    /// Shared tail of `closeFocusedTab()`/`requestCloseFocusedTab()`'s
    /// non-terminal branch. `closePane(id:refuseIfAppsLastPane:)` is
    /// `@discardableResult` and can in principle return anything but
    /// `.closed` (`.needsConfirmation` already logs its own refusal
    /// there; `.refusedLastPane` can't happen with `refuseIfAppsLastPane:
    /// false`; `.unknownPane` doesn't log anywhere). Logging any
    /// non-`.closed` outcome here means ⌘W on a non-terminal pane can
    /// never become a silent no-op, today or if `needsConfirmClose`'s
    /// polyfill (`TerminalViewState+Polyfill.swift`) is ever replaced by
    /// the real thing (#0334 review).
    private func closeFocusedNonTerminalPane(_ paneID: UUID) {
        let outcome = closePane(id: paneID, refuseIfAppsLastPane: false)
        if outcome != .closed {
            logger.notice("closeFocusedNonTerminalPane: pane=\(paneID, privacy: .public) outcome=\(String(describing: outcome), privacy: .public), expected .closed")
        }
    }

    public func requestCloseOtherTabs(paneID: UUID, keepingTabID: UUID) {
        guard let pane = sessions
            .flatMap({ $0.tree.allPanes })
            .first(where: { $0.id == paneID }) else { return }
        let victims = pane.tabs.filter { $0.id != keepingTabID }
        let busy = victims.filter { $0.terminal.needsConfirmClose }
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
        }
    }

    public func cancelPendingClose() {
        pendingCloseRequest = nil
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
    @discardableResult
    public func closePane(id paneID: UUID, refuseIfAppsLastPane: Bool) -> PaneCloseOutcome {
        for session in sessions {
            guard let pane = session.tree.allPanes.first(where: { $0.id == paneID }) else { continue }
            if pane.tabs.contains(where: { $0.terminal.needsConfirmClose }) {
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
            let treeEmptied = session.tree.removePane(id: pane.id)
            if treeEmptied {
                logger.info("closePane tree empty for session=\(session.id, privacy: .public); removing session")
                removeSession(id: session.id)
            } else if let focused = session.tree.allPanes.first(where: { $0.id == session.tree.focusedPaneID }),
                      focused.isHidden {
                // #0256 binds "never leave focus on a hidden pane" — full
                // stop, not conditioned on whether some other pane is still
                // visible. `SplitTree.removePane` reassigns `focusedPaneID`
                // to `firstLeafPaneID` (the tree's leftmost leaf) whenever
                // the closed pane was focused, with no regard for `isHidden`
                // — that leaf can be hidden even while a different, visible
                // pane exists elsewhere in the tree. Prefer moving focus to
                // that visible pane (mirrors `hidePane`'s own focus move);
                // only when none exists (every remaining pane hidden, so
                // `visiblePanes` is empty) is there nothing to move to, and
                // the hidden focused pane itself un-hides so the session
                // isn't rendered blank (#0256's "≥1 visible pane" rule).
                if let nextVisible = session.tree.visiblePanes.first {
                    logger.notice("closePane: session=\(session.id, privacy: .public) focus dangled on hidden pane=\(focused.id, privacy: .public); moving to visible=\(nextVisible.id, privacy: .public)")
                    session.tree.focusedPaneID = nextVisible.id
                } else {
                    logger.notice("closePane: session=\(session.id, privacy: .public) left with no visible panes; un-hiding focusedPaneID=\(focused.id, privacy: .public)")
                    showPane(id: focused.id)
                }
            }
            return .closed
        }
        return .unknownPane
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
            return
        }
    }

    /// Un-hides the pane with `id`. No-op when the pane is already visible.
    public func showPane(id: UUID) {
        for session in sessions {
            guard let pane = session.tree.allPanes.first(where: { $0.id == id }) else { continue }
            guard pane.isHidden else { return }
            pane.isHidden = false
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
        guard let session = selectedSession else { return }
        let pane = session.focusedPane
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
