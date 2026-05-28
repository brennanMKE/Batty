// AppStateStore.swift

import Foundation
import Observation
import OSLog

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "AppStateStore")

@Observable
public final class AppStateStore {
    public static let shared = AppStateStore()
    public private(set) var sessions: [SessionRuntime]
    public var selectedSessionID: UUID?
    public let bellFeed: BellFeedStore
    public let nameCache: SessionNameCache
    public let themeChrome: ThemeChrome
    @ObservationIgnored public var notifier: BellNotifying?
    /// Called when `removeSession` empties `sessions`. Nil in unit tests;
    /// the app delegate sets this to terminate the process. (#0217)
    @ObservationIgnored public var onAllSessionsClosed: (() -> Void)?

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

    @discardableResult
    public func addSession(title: String? = nil) -> SessionRuntime {
        let sourceTab = selectedSession?.focusedPane.activeTab
        let inheritedCWD = sourceTab?.terminal.workingDirectory
            ?? sourceTab?.terminal.configuration.workingDirectory
        let cachedName: String? = {
            guard title == nil, let cwd = inheritedCWD, !cwd.isEmpty else { return nil }
            return nameCache.lookup(path: cwd)
        }()
        let resolvedTitle = title ?? cachedName ?? String(localized: "Session \(sessions.count + 1)")
        let firstPane = PaneRuntime(tabs: [TabRuntime(workingDirectory: inheritedCWD)])
        let tree = SplitTree(root: .leaf(firstPane))
        let session = SessionRuntime(title: resolvedTitle, tree: tree)
        sessions.append(session)
        selectedSessionID = session.id
        return session
    }

    public func removeSession(id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else {
            logger.warning("removeSession id=\(id, privacy: .public) not found in store")
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
        // A user-set rename pins the title — subsequent auto-naming
        // paths (name cache, project-name resolver) must respect it.
        session.titleOverride = true
        guard !Self.isDefaultSessionTitle(trimmed) else { return }
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

    private static let defaultSessionTitlePattern: Regex<Substring> = {
        // swiftlint:disable:next force_try
        try! Regex(#"^Session \d+$"#)
    }()

    static func isDefaultSessionTitle(_ title: String) -> Bool {
        title.wholeMatch(of: defaultSessionTitlePattern) != nil
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

    // MARK: - Bell event routing

    public func recordBellTick(forTabID tabID: UUID, surfaceID: UUID = UUID(), windowID: UUID = UUID()) {
        guard let location = locate(tabID: tabID) else { return }
        let delta = location.tab.recordBellTickIfNeeded()
        guard delta > 0 else { return }
        for _ in 0..<delta {
            let entry = BellFeedEntry(
                timestamp: location.tab.lastBellAt ?? Date(),
                windowID: windowID,
                sessionID: location.session.id,
                paneID: location.pane.id,
                tabID: location.tab.id,
                surfaceID: surfaceID,
                message: nil,
                seen: location.isFocused
            )
            bellFeed.record(entry)
            propagateUnseen(at: location)
            postNotification(for: entry, at: location)
        }
    }

    public func recordDesktopNotification(forTabID tabID: UUID, surfaceID: UUID = UUID(), windowID: UUID = UUID()) {
        guard let location = locate(tabID: tabID) else { return }
        guard location.tab.recordDesktopNotificationIfNeeded() else { return }
        let entry = BellFeedEntry(
            timestamp: location.tab.lastBellAt ?? Date(),
            windowID: windowID,
            sessionID: location.session.id,
            paneID: location.pane.id,
            tabID: location.tab.id,
            surfaceID: surfaceID,
            message: location.tab.lastBellMessage,
            seen: location.isFocused
        )
        bellFeed.record(entry)
        propagateUnseen(at: location)
        postNotification(for: entry, at: location)
    }

    public func markBellSeen(id: UUID) {
        guard let entry = bellFeed.markSeen(id: id) else { return }
        decrementUnseen(for: entry)
    }

    public func markAllBellsSeen() {
        let touched = bellFeed.markAllSeen()
        for entry in touched {
            decrementUnseen(for: entry)
        }
    }

    /// Marks every bell-feed entry whose `tabID` matches the actively viewed
    /// tab as seen, then zeroes the tab's `unseenBellCount` (with cascade
    /// onto the pane and session aggregates) to cover entries that were
    /// evicted from the feed cap before they could be cleared. Called on
    /// every focus-changing path — sidebar selection, pane focus, tab
    /// switch — so visiting a tab acknowledges its bells the way Mail,
    /// iMessage, and Slack do.
    public func markActiveTabSeen() {
        guard let session = selectedSession else { return }
        let pane = session.focusedPane
        let tabID = pane.activeTabID
        let entriesToClear = bellFeed.entries.filter { $0.tabID == tabID && !$0.seen }
        for entry in entriesToClear {
            markBellSeen(id: entry.id)
        }
        guard let tab = pane.tabs.first(where: { $0.id == tabID }) else { return }
        guard tab.unseenBellCount > 0 else { return }
        let residual = tab.unseenBellCount
        tab.unseenBellCount = 0
        pane.unseenBellCount = max(0, pane.unseenBellCount - residual)
        session.unseenBellCount = max(0, session.unseenBellCount - residual)
    }

    // MARK: - Tab close cascade

    /// Closes a specific tab, cascading through pane and session teardown
    /// when it was the last tab in its pane / the last pane in its session.
    /// Restores a single default session if the close would leave the store
    /// with zero sessions, mirroring `removeSession`'s recovery.
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

    /// Closes the currently-focused tab in the selected session, cascading
    /// through pane and session teardown as needed.
    public func closeFocusedTab() {
        guard let session = selectedSession else { return }
        closeTab(id: session.focusedPane.activeTabID)
    }

    /// Pending tab-close that's awaiting user confirmation. The view layer
    /// observes this and presents a `.confirmationDialog`. Cleared on
    /// confirm or cancel.
    public var pendingCloseRequest: PendingCloseRequest?

    /// Requests a tab close that runs through the busy check. If the tab's
    /// terminal reports `needsConfirmClose`, sets `pendingCloseRequest`
    /// so the view can prompt; otherwise commits the close directly.
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

    /// Convenience for the focused tab.
    public func requestCloseFocusedTab() {
        guard let session = selectedSession else { return }
        requestCloseTab(id: session.focusedPane.activeTabID)
    }

    /// Requests "Close Other Tabs in this pane, keeping `keepingTabID`."
    /// If any of the tabs to close are busy, prompts; otherwise commits
    /// directly.
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

    /// Confirms the pending request — actually performs the close. Caller
    /// then clears `pendingCloseRequest` (or `cancelPendingClose` does it).
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

    private static func runningLabel(for tab: TabRuntime) -> String {
        let title = tab.terminal.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty || title.contains(":") || title.contains("@") {
            return String(localized: "A process")
        }
        return "`\(title)`"
    }

    /// Marks the pane with `id` as the focused pane in its owning session.
    /// No-op if the pane id doesn't belong to any session in the store.
    /// Does not change the selected session — cross-session focus moves
    /// belong to `jumpToBellEntry` / sidebar selection.
    public func focusPane(id: UUID) {
        for session in sessions {
            if session.tree.allPanes.contains(where: { $0.id == id }) {
                session.tree.focusedPaneID = id
                return
            }
        }
    }

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
        for (index, session) in sessions.enumerated() {
            let anchorTab = session.tree.root.firstLeafPane.tabs[0]
            guard anchorTab.id == tabID else { continue }
            guard !session.titleOverride else { return }
            guard session.tree.allPanes.count == 1 else { return }
            let cwd = anchorTab.terminal.workingDirectory
                ?? anchorTab.terminal.configuration.workingDirectory
            guard let cwd, !cwd.isEmpty else { return }
            let resolved = Self.resolveAutoTitle(
                forCWD: cwd,
                sessionIndex: index,
                cache: nameCache,
                resolver: ProjectNameResolver.shared
            )
            guard resolved != session.title else { return }
            logger.info("auto-rename session \(session.title, privacy: .public) -> \(resolved, privacy: .public) for cwd=\(cwd, privacy: .public)")
            session.title = resolved
            return
        }
    }

    /// Pure decision function for the single-pane CWD-driven auto-naming
    /// chain: cache hit > project-name extraction > default `Session N`.
    /// The default is the only branch that resets a title when the shell
    /// walks *out* of a project directory (`#0213`). Caller is responsible
    /// for the single-pane and `titleOverride` gates.
    static func resolveAutoTitle(
        forCWD cwd: String,
        sessionIndex: Int,
        cache: SessionNameCache,
        resolver: ProjectNameResolver.Resolver
    ) -> String {
        if let cachedName = cache.lookup(path: cwd) {
            return cachedName
        }
        if let derivedName = resolver.resolve(at: cwd) {
            return derivedName
        }
        return String(localized: "Session \(sessionIndex + 1)")
    }

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

    private struct BellLocation {
        let session: SessionRuntime
        let pane: PaneRuntime
        let tab: TabRuntime
        let isFocused: Bool
    }

    private func locate(tabID: UUID) -> BellLocation? {
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

    private func propagateUnseen(at location: BellLocation) {
        guard !location.isFocused else { return }
        location.tab.unseenBellCount += 1
        location.pane.unseenBellCount += 1
        location.session.unseenBellCount += 1
    }

    private func postNotification(for entry: BellFeedEntry, at location: BellLocation) {
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

    private func decrementUnseen(for entry: BellFeedEntry) {
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

    private func cleanUpBellState(forTabIDs tabIDs: Set<UUID>) {
        let removed = bellFeed.removeEntries(matchingTabIDs: tabIDs)
        for entry in removed where !entry.seen {
            decrementUnseen(for: entry)
        }
    }
}
