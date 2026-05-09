// WorkspaceConversion.swift

import Foundation

extension Tab {
    init(from runtime: TabRuntime) {
        self.init(
            id: runtime.id,
            surfaceID: UUID(),
            titleOverride: runtime.titleOverride,
            lastKnownCWD: nil,
            lastSetTitle: runtime.terminal.title.isEmpty ? nil : runtime.terminal.title,
            bellCount: 0,
            unseenBellCount: 0,
            lastBellAt: nil,
            lastBellMessage: nil
        )
    }
}

extension Pane {
    init(from runtime: PaneRuntime) {
        self.init(
            id: runtime.id,
            tabs: runtime.tabs.map { Tab(from: $0) },
            activeTabID: runtime.activeTabID,
            unseenBellCount: 0
        )
    }
}

extension SplitNode {
    init(from runtime: SplitTreeNode) {
        switch runtime {
        case .leaf(let pane):
            self = .leaf(Pane(from: pane))
        case .split(_, let direction, let ratio, let left, let right):
            self = .split(
                direction: direction,
                ratio: ratio,
                left: SplitNode(from: left),
                right: SplitNode(from: right)
            )
        }
    }
}

extension Session {
    init(from runtime: SessionRuntime) {
        self.init(
            id: runtime.id,
            title: runtime.title,
            icon: nil,
            root: SplitNode(from: runtime.tree.root),
            focusedPaneID: runtime.tree.focusedPaneID,
            unseenBellCount: 0
        )
    }
}

extension WindowState {
    init(from runtime: AppStateStore, sidebarHidden: Bool = false) {
        self.init(
            id: UUID(),
            frame: nil,
            isZoomed: false,
            sidebarCollapsed: sidebarHidden,
            selectedSessionID: runtime.selectedSessionID,
            sessions: runtime.sessions.map { Session(from: $0) }
        )
    }
}

extension TabRuntime {
    convenience init(from persisted: Tab) {
        self.init(id: persisted.id, titleOverride: persisted.titleOverride)
    }
}

extension PaneRuntime {
    convenience init(from persisted: Pane) {
        let runtimeTabs = persisted.tabs.map { TabRuntime(from: $0) }
        self.init(id: persisted.id, tabs: runtimeTabs)
        self.activeTabID = persisted.activeTabID
    }
}

extension SplitTreeNode {
    init(from persisted: SplitNode) {
        switch persisted {
        case .leaf(let pane):
            self = .leaf(PaneRuntime(from: pane))
        case .split(let direction, let ratio, let left, let right):
            self = .split(
                id: UUID(),
                direction: direction,
                ratio: ratio,
                left: SplitTreeNode(from: left),
                right: SplitTreeNode(from: right)
            )
        }
    }
}

extension SessionRuntime {
    convenience init(from persisted: Session) {
        let tree = SplitTree(root: SplitTreeNode(from: persisted.root))
        tree.focusedPaneID = persisted.focusedPaneID
        self.init(id: persisted.id, title: persisted.title, tree: tree)
    }
}

extension AppStateStore {
    convenience init(from windowState: WindowState) {
        let runtimeSessions = windowState.sessions.map { SessionRuntime(from: $0) }
        self.init(sessions: runtimeSessions)
        if let selectedID = windowState.selectedSessionID,
           runtimeSessions.contains(where: { $0.id == selectedID }) {
            self.selectedSessionID = selectedID
        }
    }
}
