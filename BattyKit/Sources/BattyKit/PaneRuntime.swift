// PaneRuntime.swift

import Foundation
import Observation

@Observable
public final class PaneRuntime: Identifiable {
    public let id: UUID
    public var tabs: [TabRuntime]
    public var activeTabID: UUID

    public init(id: UUID = UUID(), tabs: [TabRuntime]? = nil) {
        self.id = id
        let initial = tabs ?? [TabRuntime()]
        precondition(!initial.isEmpty, "PaneRuntime must contain at least one Tab")
        self.tabs = initial
        self.activeTabID = initial[0].id
    }

    public var activeTab: TabRuntime {
        tabs.first { $0.id == activeTabID } ?? tabs[0]
    }

    @discardableResult
    public func addTab() -> TabRuntime {
        let tab = TabRuntime()
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
}
