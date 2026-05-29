// PaneRuntimeActiveTabTests.swift

import Foundation
import Testing
@testable import BattyKit

@MainActor
struct PaneRuntimeActiveTabTests {

    @Test func activeTabIsNilAfterRemovingLastTab() {
        let pane = PaneRuntime()
        let onlyTabID = pane.tabs[0].id
        #expect(pane.tabs.count == 1)

        pane.removeTab(id: onlyTabID)

        #expect(pane.tabs.isEmpty)
        #expect(pane.activeTab == nil)
    }

    @Test func activeTabFallsBackToFirstTabWhenActiveIDIsStale() {
        let pane = PaneRuntime()
        let firstID = pane.tabs[0].id
        pane.activeTabID = UUID()

        #expect(pane.activeTab?.id == firstID)
    }
}
