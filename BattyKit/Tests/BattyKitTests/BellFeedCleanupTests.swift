// BellFeedCleanupTests.swift

import Foundation
import Testing
@testable import BattyKit

@MainActor
struct BellFeedCleanupTests {

    @Test func closingTabRemovesItsFeedEntriesAndDecrementsAggregates() async {
        let store = AppStateStore()
        store.isBattyActiveProvider = { false }
        let focused = store.sessions[0]
        let background = store.addSession(title: "Background")!
        store.selectedSessionID = focused.id

        let pane = background.tree.allPanes[0]
        background.focusedPaneAnyKind.addTab()
        let tabA = pane.tabs[0]
        let tabB = pane.tabs[1]
        pane.activeTabID = tabA.id

        store.ringBell(in: tabA)
        store.ringBell(in: tabB)

        #expect(store.bellFeed.entries.count == 2)
        #expect(pane.unseenBellCount == 2)
        #expect(background.unseenBellCount == 2)

        let tabAID = tabA.id
        store.closeTab(id: tabAID)

        #expect(store.bellFeed.entries.contains { $0.tabID == tabAID } == false)
        #expect(store.bellFeed.entries.contains { $0.tabID == tabB.id })
        #expect(store.bellFeed.entries.count == 1)
        #expect(pane.unseenBellCount == 1)
        #expect(background.unseenBellCount == 1)
        #expect(tabB.unseenBellCount == 1)
    }

    @Test func closingTabDoesNotTouchOtherTabsEntries() async {
        let store = AppStateStore()
        store.isBattyActiveProvider = { false }
        let focused = store.sessions[0]
        let background = store.addSession()!
        store.selectedSessionID = focused.id

        let pane = background.tree.allPanes[0]
        background.focusedPaneAnyKind.addTab()
        let tabA = pane.tabs[0]
        let tabB = pane.tabs[1]
        pane.activeTabID = tabA.id

        store.ringBell(in: tabB)
        #expect(store.bellFeed.entries.first != nil)
        let entryID = store.bellFeed.entries[0].id

        store.closeTab(id: tabA.id)

        #expect(store.bellFeed.entries.count == 1)
        #expect(store.bellFeed.entries.first?.id == entryID)
        #expect(tabB.unseenBellCount == 1)
        #expect(pane.unseenBellCount == 1)
        #expect(background.unseenBellCount == 1)
    }

    @Test func closingLastTabInPaneClearsItsEntries() async {
        let store = AppStateStore()
        store.isBattyActiveProvider = { false }
        let focused = store.sessions[0]
        let background = store.addSession()!
        store.selectedSessionID = focused.id

        let originalPane = background.tree.allPanes[0]
        background.tree.splitFocusedPane(direction: .horizontal)
        #expect(background.tree.allPanes.count == 2)

        let originalTab = originalPane.tabs[0]
        store.ringBell(in: originalTab)

        #expect(store.bellFeed.entries.count == 1)
        #expect(background.unseenBellCount == 1)

        store.closeTab(id: originalTab.id)

        #expect(background.tree.allPanes.count == 1)
        #expect(store.bellFeed.entries.isEmpty)
        #expect(background.unseenBellCount == 0)
    }

    @Test func closingLastTabCascadingToSessionClearsItsEntries() async {
        let store = AppStateStore()
        store.isBattyActiveProvider = { false }
        let focused = store.sessions[0]
        let background = store.addSession(title: "Background")!
        store.selectedSessionID = focused.id

        let pane = background.tree.allPanes[0]
        let tab = pane.tabs[0]
        store.ringBell(in: tab)
        store.ringBell(in: tab)

        // #0298: both bare BELs are still unseen and share this tab, so the
        // second collapses into the first rather than appending a second
        // entry -- see BellFeedCollapseTests for the rule itself.
        #expect(store.bellFeed.entries.count == 1)
        #expect(store.bellFeed.entries.first?.repeatCount == 2)

        store.closeTab(id: tab.id)

        #expect(store.sessions.contains { $0.id == background.id } == false)
        #expect(store.bellFeed.entries.isEmpty)
    }

    @Test func removeSessionDirectlyClearsAllEntriesUnderIt() async {
        let store = AppStateStore()
        store.isBattyActiveProvider = { false }
        let focused = store.sessions[0]
        let background = store.addSession()!
        store.selectedSessionID = focused.id

        let pane = background.tree.allPanes[0]
        background.focusedPaneAnyKind.addTab()
        let tabA = pane.tabs[0]
        let tabB = pane.tabs[1]
        pane.activeTabID = tabA.id

        store.ringBell(in: tabA)
        store.ringBell(in: tabB)

        let backgroundID = background.id
        #expect(store.bellFeed.entries.count == 2)

        store.removeSession(id: backgroundID)

        #expect(store.sessions.contains { $0.id == backgroundID } == false)
        #expect(store.bellFeed.entries.isEmpty)
    }

    @Test func cleanupLeavesSeenEntriesAlone() async {
        let store = AppStateStore()
        store.isBattyActiveProvider = { false }
        let session = store.sessions[0]
        let pane = session.tree.allPanes[0]
        let tab = pane.tabs[0]

        store.ringBell(in: tab)
        #expect(store.bellFeed.entries.first != nil)
        #expect(store.bellFeed.entries.first?.seen == true)
        #expect(session.unseenBellCount == 0)

        let removed = store.bellFeed.removeEntries(matchingTabIDs: [tab.id])
        #expect(removed.count == 1)
        #expect(removed.first?.seen == true)
    }
}
