// WindowRuntime.swift

import Foundation
import Observation
import OSLog

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "WindowRuntime")

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
            let initial = SessionRuntime(title: String(localized: "Session 1"))
            self.sessions = [initial]
            self.selectedSessionID = initial.id
        } else {
            self.sessions = sessions
            self.selectedSessionID = sessions.first?.id
        }
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
        let session = SessionRuntime(title: resolvedTitle, tree: tree)
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
        let copy = SessionRuntime(title: String(localized: "\(source.title) Copy"))
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

    public func closeFocusedTab() {
        guard let session = selectedSession else { return }
        closeTab(id: session.focusedPane.activeTabID)
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

    public func requestCloseFocusedTab() {
        guard let session = selectedSession else { return }
        requestCloseTab(id: session.focusedPane.activeTabID)
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

    // MARK: - Navigation

    public func jumpToTab(sessionID: UUID, tabID: UUID) {
        guard let session = sessions.first(where: { $0.id == sessionID }),
              let pane = session.tree.allPanes.first(where: { $0.tabs.contains(where: { $0.id == tabID }) })
        else { return }
        selectedSessionID = session.id
        session.tree.focusedPaneID = pane.id
        pane.activeTabID = tabID
    }

    public func jumpToBellEntry(_ entry: BellFeedEntry) {
        guard let session = sessions.first(where: { $0.id == entry.sessionID }),
              let pane = session.tree.allPanes.first(where: { $0.id == entry.paneID }),
              pane.tabs.contains(where: { $0.id == entry.tabID })
        else { return }
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

    func decrementUnseen(for entry: BellFeedEntry) {
        for session in sessions where session.id == entry.sessionID {
            if session.unseenBellCount > 0 { session.unseenBellCount -= 1 }
            for pane in session.tree.allPanes where pane.id == entry.paneID {
                if pane.unseenBellCount > 0 { pane.unseenBellCount -= 1 }
                for tab in pane.tabs where tab.id == entry.tabID {
                    if tab.unseenBellCount > 0 { tab.unseenBellCount -= 1 }
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
