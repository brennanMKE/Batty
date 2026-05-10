// AppStateStore.swift

import Foundation
import Observation

@Observable
public final class AppStateStore {
    public private(set) var sessions: [SessionRuntime]
    public var selectedSessionID: UUID?
    public let bellFeed: BellFeedStore

    public init(
        sessions: [SessionRuntime] = [],
        bellFeed: BellFeedStore = BellFeedStore()
    ) {
        self.bellFeed = bellFeed
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
        let resolvedTitle = title ?? "Session \(sessions.count + 1)"
        let session = SessionRuntime(title: resolvedTitle)
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
