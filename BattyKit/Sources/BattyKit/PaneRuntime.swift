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

    public func removeTab(id: UUID) {
        guard tabs.count > 1, let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: index)
        if activeTabID == id {
            activeTabID = tabs[max(0, index - 1)].id
        }
    }

    public func closeActiveTab() {
        removeTab(id: activeTabID)
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
