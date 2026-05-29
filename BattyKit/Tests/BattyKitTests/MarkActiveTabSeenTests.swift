// MarkActiveTabSeenTests.swift

import Foundation
import Testing
@testable import BattyKit

@MainActor
struct MarkActiveTabSeenTests {

    @Test func markActiveTabSeenClearsCountsAndEntries() {
        let store = AppStateStore()
        let focused = store.sessions[0]
        let background = store.addSession(title: "Background")
        store.selectedSessionID = focused.id

        let pane = background.tree.allPanes[0]
        let tab = pane.tabs[0]

        tab.terminal.terminalDidRingBell()
        store.recordBellTick(forTabID: tab.id)
        tab.terminal.terminalDidRingBell()
        store.recordBellTick(forTabID: tab.id)

        #expect(tab.unseenBellCount == 2)
        #expect(pane.unseenBellCount == 2)
        #expect(background.unseenBellCount == 2)

        store.selectedSessionID = background.id
        background.tree.focusedPaneID = pane.id
        pane.activeTabID = tab.id
        store.markActiveTabSeen()

        #expect(tab.unseenBellCount == 0)
        #expect(pane.unseenBellCount == 0)
        #expect(background.unseenBellCount == 0)
        #expect(store.bellFeed.entries.allSatisfy { $0.seen })
    }

    @Test func markActiveTabSeenZeroesTabEvenWhenEntryEvicted() {
        let store = AppStateStore()
        let focused = store.sessions[0]
        let background = store.addSession(title: "Background")
        store.selectedSessionID = focused.id

        let pane = background.tree.allPanes[0]
        let tab = pane.tabs[0]

        // One real bell tick lands on the tab/pane/session aggregates...
        tab.terminal.terminalDidRingBell()
        store.recordBellTick(forTabID: tab.id)
        #expect(tab.unseenBellCount == 1)

        // ...then we overflow the feed cap with synthetic entries from a
        // different tab so the original entry is evicted while the
        // aggregates still hold the count.
        let evictedSession = store.addSession(title: "Filler")
        let evictedPane = evictedSession.tree.allPanes[0]
        let evictedTab = evictedPane.tabs[0]
        for _ in 0..<(BellFeedStore.cap + 5) {
            evictedTab.terminal.terminalDidRingBell()
            store.recordBellTick(forTabID: evictedTab.id)
        }

        #expect(!store.bellFeed.entries.contains { $0.tabID == tab.id })
        #expect(tab.unseenBellCount == 1)

        store.selectedSessionID = background.id
        background.tree.focusedPaneID = pane.id
        pane.activeTabID = tab.id
        store.markActiveTabSeen()

        #expect(tab.unseenBellCount == 0)
        #expect(pane.unseenBellCount == 0)
        #expect(background.unseenBellCount == 0)
    }

    @Test func markActiveTabSeenWithNoUnseenIsNoOp() {
        let store = AppStateStore()
        let session = store.sessions[0]
        let pane = session.tree.allPanes[0]
        let tab = pane.tabs[0]

        #expect(tab.unseenBellCount == 0)
        #expect(pane.unseenBellCount == 0)
        #expect(session.unseenBellCount == 0)

        store.markActiveTabSeen()
        store.markActiveTabSeen()

        #expect(tab.unseenBellCount == 0)
        #expect(pane.unseenBellCount == 0)
        #expect(session.unseenBellCount == 0)
        #expect(store.bellFeed.entries.isEmpty)
    }

    @Test func markActiveTabSeenLeavesOtherTabsAlone() {
        let store = AppStateStore()
        let focused = store.sessions[0]
        let background = store.addSession(title: "Background")
        store.selectedSessionID = focused.id

        let pane = background.tree.allPanes[0]
        pane.addTab()
        let firstTab = pane.tabs[0]
        let secondTab = pane.tabs[1]
        pane.activeTabID = firstTab.id

        firstTab.terminal.terminalDidRingBell()
        store.recordBellTick(forTabID: firstTab.id)
        secondTab.terminal.terminalDidRingBell()
        store.recordBellTick(forTabID: secondTab.id)

        #expect(firstTab.unseenBellCount == 1)
        #expect(secondTab.unseenBellCount == 1)
        #expect(pane.unseenBellCount == 2)
        #expect(background.unseenBellCount == 2)

        store.selectedSessionID = background.id
        background.tree.focusedPaneID = pane.id
        pane.activeTabID = firstTab.id
        store.markActiveTabSeen()

        #expect(firstTab.unseenBellCount == 0)
        #expect(secondTab.unseenBellCount == 1)
        #expect(pane.unseenBellCount == 1)
        #expect(background.unseenBellCount == 1)
    }
}
