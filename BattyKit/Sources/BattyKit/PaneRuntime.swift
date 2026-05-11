// PaneRuntime.swift

import Foundation
import Observation

@Observable
public final class PaneRuntime: Identifiable {
    public let id: UUID
    public var tabs: [TabRuntime]
    public var activeTabID: UUID
    public internal(set) var unseenBellCount: Int = 0

    public init(
        id: UUID = UUID(),
        tabs: [TabRuntime]? = nil,
        unseenBellCount: Int = 0
    ) {
        self.id = id
        let initial = tabs ?? [TabRuntime()]
        precondition(!initial.isEmpty, "PaneRuntime must contain at least one Tab")
        self.tabs = initial
        self.activeTabID = initial[0].id
        self.unseenBellCount = unseenBellCount
    }

    public var activeTab: TabRuntime {
        tabs.first { $0.id == activeTabID } ?? tabs[0]
    }

    @discardableResult
    public func addTab(inheritingCWDFrom source: TabRuntime? = nil) -> TabRuntime {
        let cwd = source?.terminal.workingDirectory
        let tab = TabRuntime(workingDirectory: cwd)
        tabs.append(tab)
        activeTabID = tab.id
        return tab
    }

    /// Removes a tab by id. Allows the pane to become empty — callers
    /// must handle the empty case (typically by removing the pane).
    /// Use ``AppStateStore/closeTab(id:)`` for the full cascade.
    public func removeTab(id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: index)
        if !tabs.isEmpty, activeTabID == id {
            activeTabID = tabs[max(0, index - 1)].id
        }
    }

    public func closeActiveTab() {
        removeTab(id: activeTabID)
    }

    /// Removes every tab in the pane except the one with `id`. Used by the
    /// chip context menu's "Close Other Tabs". The kept tab becomes active.
    public func closeOtherTabs(keeping id: UUID) {
        guard let kept = tabs.first(where: { $0.id == id }) else { return }
        tabs = [kept]
        activeTabID = kept.id
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
