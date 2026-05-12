// AppStateStore.swift

import Foundation
import Observation
import OSLog

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "AppStateStore")

@Observable
public final class AppStateStore {
    public private(set) var sessions: [SessionRuntime]
    public var selectedSessionID: UUID?
    public let bellFeed: BellFeedStore
    public let nameCache: SessionNameCache
    @ObservationIgnored public var notifier: BellNotifier?

    public init(
        sessions: [SessionRuntime] = [],
        bellFeed: BellFeedStore = BellFeedStore(),
        nameCache: SessionNameCache = SessionNameCache(),
        notifier: BellNotifier? = nil
    ) {
        self.bellFeed = bellFeed
        self.nameCache = nameCache
        self.notifier = notifier
        if sessions.isEmpty {
            let initial = SessionRuntime(title: "Session 1")
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
        let resolvedTitle = title ?? cachedName ?? "Session \(sessions.count + 1)"
        let firstPane = PaneRuntime(tabs: [TabRuntime(workingDirectory: inheritedCWD)])
        let tree = SplitTree(root: .leaf(firstPane))
        let session = SessionRuntime(title: resolvedTitle, tree: tree)
        sessions.append(session)
        selectedSessionID = session.id
        return session
    }

    public func removeSession(id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions.remove(at: index)
        if selectedSessionID == id {
            selectedSessionID = sessions.first?.id
        }
        if sessions.isEmpty {
            addSession()
        }
    }

    public func renameSession(id: UUID, to newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        session.title = trimmed
        guard !Self.isDefaultSessionTitle(trimmed) else { return }
        let firstTab = session.tree.root.firstLeafPane.tabs[0]
        let cwd = firstTab.terminal.workingDirectory
            ?? firstTab.terminal.configuration.workingDirectory
        guard let cwd, !cwd.isEmpty else { return }
        nameCache.record(path: cwd, name: trimmed)
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
        let copy = SessionRuntime(title: "\(source.title) Copy")
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

    // MARK: - Tab close cascade

    /// Closes a specific tab, cascading through pane and session teardown
    /// when it was the last tab in its pane / the last pane in its session.
    /// Restores a single default session if the close would leave the store
    /// with zero sessions, mirroring `removeSession`'s recovery.
    public func closeTab(id tabID: UUID) {
        for session in sessions {
            for pane in session.tree.allPanes where pane.tabs.contains(where: { $0.id == tabID }) {
                pane.removeTab(id: tabID)
                if pane.tabs.isEmpty {
                    let treeEmptied = session.tree.removePane(id: pane.id)
                    if treeEmptied {
                        removeSession(id: session.id)
                    }
                }
                return
            }
        }
    }

    /// Closes the currently-focused tab in the selected session, cascading
    /// through pane and session teardown as needed.
    public func closeFocusedTab() {
        guard let session = selectedSession else { return }
        closeTab(id: session.focusedPane.activeTabID)
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
    /// to a CWD that has a cached name, apply that name as the session title.
    /// Mirrors the write rule in `renameSession` — only the anchor tab's CWD
    /// drives auto-naming.
    public func handleWorkingDirectoryChange(forTabID tabID: UUID) {
        for session in sessions {
            let anchorTab = session.tree.root.firstLeafPane.tabs[0]
            guard anchorTab.id == tabID else { continue }
            let cwd = anchorTab.terminal.workingDirectory
                ?? anchorTab.terminal.configuration.workingDirectory
            guard let cwd, !cwd.isEmpty else { return }
            guard let cachedName = nameCache.lookup(path: cwd) else { return }
            guard cachedName != session.title else { return }
            logger.info("auto-rename session \(session.title, privacy: .public) -> \(cachedName, privacy: .public) for cwd=\(cwd, privacy: .public)")
            session.title = cachedName
            return
        }
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
        let paneIndex = (location.session.tree.allPanes.firstIndex { $0.id == location.pane.id } ?? 0) + 1
        let tabIndex = (location.pane.tabs.firstIndex { $0.id == location.tab.id } ?? 0) + 1
        let tabLabel: String
        if let override = location.tab.titleOverride, !override.isEmpty {
            tabLabel = override
        } else if !location.tab.terminal.title.isEmpty {
            tabLabel = location.tab.terminal.title
        } else {
            tabLabel = "Tab \(tabIndex)"
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
}
