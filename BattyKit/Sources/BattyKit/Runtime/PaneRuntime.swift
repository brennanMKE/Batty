// PaneRuntime.swift

import Foundation
import Observation

@Observable
public final class PaneRuntime: Identifiable {
    public let id: UUID
    public var tabs: [TabRuntime]
    public var activeTabID: UUID
    public internal(set) var unseenBellCount: Int = 0
    /// Whether this pane is hidden from view. The Ghostty surface (PTY +
    /// scrollback) keeps running; only the placement in `TerminalHostStore`
    /// is zeroed. Tree structure is unchanged — hidden is a leaf property.
    public var isHidden: Bool = false

    /// The owning session, set by ``attachToSession(_:)`` once this pane
    /// joins a `SessionRuntime`'s `SplitTree`. `nil` for a pane not yet
    /// attached (see `TabRuntime.attachContext(paneID:sessionID:)` for why
    /// this is deferred rather than known at `init`).
    public internal(set) var sessionID: UUID?

    public init(
        id: UUID = UUID(),
        tabs: [TabRuntime]? = nil,
        unseenBellCount: Int = 0,
        isHidden: Bool = false
    ) {
        self.id = id
        let initial = tabs ?? [TabRuntime()]
        precondition(!initial.isEmpty, "PaneRuntime must contain at least one Tab")
        self.tabs = initial
        self.activeTabID = initial[0].id
        self.unseenBellCount = unseenBellCount
        self.isHidden = isHidden
    }

    /// A `Pane` value-type snapshot suitable for workspace persistence.
    public func snapshot() -> Pane {
        Pane(id: id, isHidden: isHidden)
    }

    public var activeTab: TabRuntime? {
        tabs.first { $0.id == activeTabID } ?? tabs.first
    }

    @discardableResult
    public func addTab(inheritingCWDFrom source: TabRuntime? = nil) -> TabRuntime {
        let cwd = source?.terminal.workingDirectory
        let tab = TabRuntime(workingDirectory: cwd)
        tabs.append(tab)
        activeTabID = tab.id
        if let sessionID {
            tab.attachContext(paneID: id, sessionID: sessionID)
        }
        return tab
    }

    /// Attaches this pane (and every tab it currently holds) to `sessionID`.
    /// Called by `SplitTree.attachToSession(_:)` for the tree's existing
    /// panes and by `SplitTree.splitFocusedPane`/`splitFullDimension` for a
    /// freshly-created pane — both always run before this pane's tabs can
    /// have a live libghostty surface (see `TabRuntime.attachContext`).
    public func attachToSession(_ sessionID: UUID) {
        self.sessionID = sessionID
        for tab in tabs {
            tab.attachContext(paneID: id, sessionID: sessionID)
        }
    }

    /// Removes a tab by id. Allows the pane to become empty — callers
    /// must handle the empty case (typically by removing the pane).
    /// Use ``AppStateStore/closeTab(id:)`` for the full cascade.
    ///
    /// Also releases the tab's `AppTerminalView` from the
    /// ``TerminalHostStore``. This is the one place in the app where the
    /// long-lived terminal view is removed from the host — `closeTab` is
    /// the only legitimate trigger for tearing down a libghostty surface
    /// (which kills the PTY).
    public func removeTab(id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: index)
        if !tabs.isEmpty, activeTabID == id {
            activeTabID = tabs[max(0, index - 1)].id
        }
        TerminalHostStore.shared.releaseTerminalView(forTabID: id)
    }

    public func closeActiveTab() {
        removeTab(id: activeTabID)
    }

    /// Removes every tab in the pane except the one with `id`. Used by the
    /// chip context menu's "Close Other Tabs". The kept tab becomes active.
    public func closeOtherTabs(keeping id: UUID) {
        guard let kept = tabs.first(where: { $0.id == id }) else { return }
        let removedIDs = tabs.filter { $0.id != id }.map(\.id)
        tabs = [kept]
        activeTabID = kept.id
        for removedID in removedIDs {
            TerminalHostStore.shared.releaseTerminalView(forTabID: removedID)
        }
    }

    public func selectTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        activeTabID = tabs[index].id
    }

    public func selectNextTab() {
        guard tabs.count > 1,
              let current = tabs.firstIndex(where: { $0.id == activeTabID })
        else { return }
        let next = (current + 1) % tabs.count
        activeTabID = tabs[next].id
    }

    public func selectPreviousTab() {
        guard tabs.count > 1,
              let current = tabs.firstIndex(where: { $0.id == activeTabID })
        else { return }
        let prev = (current - 1 + tabs.count) % tabs.count
        activeTabID = tabs[prev].id
    }
}
