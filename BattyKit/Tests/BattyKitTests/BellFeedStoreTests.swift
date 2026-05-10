// BellFeedStoreTests.swift

import Foundation
import Testing
@testable import BattyKit

@MainActor
struct BellFeedStoreTests {

    private func makeEntry(
        sessionID: UUID = UUID(),
        paneID: UUID = UUID(),
        tabID: UUID = UUID(),
        seen: Bool = false,
        timestamp: Date = Date()
    ) -> BellFeedEntry {
        BellFeedEntry(
            timestamp: timestamp,
            windowID: UUID(),
            sessionID: sessionID,
            paneID: paneID,
            tabID: tabID,
            surfaceID: UUID(),
            message: nil,
            seen: seen
        )
    }

    @Test func recordPrependsNewestFirst() {
        let store = BellFeedStore()
        let older = makeEntry(timestamp: Date(timeIntervalSince1970: 100))
        let newer = makeEntry(timestamp: Date(timeIntervalSince1970: 200))
        store.record(older)
        store.record(newer)
        #expect(store.entries.first?.id == newer.id)
        #expect(store.entries.last?.id == older.id)
    }

    @Test func recordCapsAt200Entries() {
        let store = BellFeedStore()
        for _ in 0..<(BellFeedStore.cap + 5) {
            store.record(makeEntry())
        }
        #expect(store.entries.count == BellFeedStore.cap)
    }

    @Test func markSeenFlipsTheEntry() {
        let store = BellFeedStore()
        let entry = makeEntry()
        store.record(entry)
        let result = store.markSeen(id: entry.id)
        #expect(result?.seen == true)
        #expect(store.entries.first?.seen == true)
    }

    @Test func markAllSeenReturnsOnlyTouchedEntries() {
        let store = BellFeedStore()
        let alreadySeen = makeEntry(seen: true)
        let unseen = makeEntry(seen: false)
        store.record(alreadySeen)
        store.record(unseen)
        let touched = store.markAllSeen()
        #expect(touched.count == 1)
        #expect(touched.first?.id == unseen.id)
    }

    @Test func unseenCountByTabFiltersCorrectly() {
        let store = BellFeedStore()
        let tabA = UUID()
        let tabB = UUID()
        store.record(makeEntry(tabID: tabA))
        store.record(makeEntry(tabID: tabA))
        store.record(makeEntry(tabID: tabB))
        store.record(makeEntry(tabID: tabA, seen: true))
        #expect(store.unseenCount(forTabID: tabA) == 2)
        #expect(store.unseenCount(forTabID: tabB) == 1)
    }
}

@MainActor
struct AppStateStoreBellRoutingTests {

    @Test func bellFromFocusedTabRecordsButLeavesUnseenAlone() {
        let store = AppStateStore()
        let session = store.sessions[0]
        let pane = session.tree.allPanes[0]
        let tab = pane.tabs[0]

        tab.terminal.terminalDidRingBell()
        store.recordBellTick(forTabID: tab.id)

        #expect(store.bellFeed.entries.count == 1)
        #expect(store.bellFeed.entries.first?.seen == true)
        #expect(tab.unseenBellCount == 0)
        #expect(pane.unseenBellCount == 0)
        #expect(session.unseenBellCount == 0)
    }

    @Test func bellFromUnfocusedTabIncrementsAllLevels() {
        let store = AppStateStore()
        let focusedSession = store.sessions[0]
        let backgroundSession = store.addSession(title: "Background")
        store.selectedSessionID = focusedSession.id

        let pane = backgroundSession.tree.allPanes[0]
        let tab = pane.tabs[0]

        tab.terminal.terminalDidRingBell()
        store.recordBellTick(forTabID: tab.id)

        #expect(store.bellFeed.entries.count == 1)
        #expect(store.bellFeed.entries.first?.seen == false)
        #expect(tab.unseenBellCount == 1)
        #expect(pane.unseenBellCount == 1)
        #expect(backgroundSession.unseenBellCount == 1)
        #expect(focusedSession.unseenBellCount == 0)
    }

    @Test func markBellSeenDecrementsAllLevels() {
        let store = AppStateStore()
        let focusedSession = store.sessions[0]
        let backgroundSession = store.addSession()
        store.selectedSessionID = focusedSession.id

        let pane = backgroundSession.tree.allPanes[0]
        let tab = pane.tabs[0]

        tab.terminal.terminalDidRingBell()
        store.recordBellTick(forTabID: tab.id)
        let entryID = store.bellFeed.entries[0].id

        store.markBellSeen(id: entryID)

        #expect(tab.unseenBellCount == 0)
        #expect(pane.unseenBellCount == 0)
        #expect(backgroundSession.unseenBellCount == 0)
    }

    @Test func markAllBellsSeenZerosCounters() {
        let store = AppStateStore()
        let focusedSession = store.sessions[0]
        let backgroundSession = store.addSession()
        store.selectedSessionID = focusedSession.id

        let pane = backgroundSession.tree.allPanes[0]
        let tab = pane.tabs[0]

        tab.terminal.terminalDidRingBell()
        store.recordBellTick(forTabID: tab.id)
        tab.terminal.terminalDidRingBell()
        store.recordBellTick(forTabID: tab.id)

        #expect(tab.unseenBellCount == 2)

        store.markAllBellsSeen()
        #expect(tab.unseenBellCount == 0)
        #expect(pane.unseenBellCount == 0)
        #expect(backgroundSession.unseenBellCount == 0)
    }

    @Test func desktopNotificationCarriesMessageThroughEntry() {
        let store = AppStateStore()
        let session = store.sessions[0]
        let pane = session.tree.allPanes[0]
        let tab = pane.tabs[0]
        store.selectedSessionID = nil

        tab.terminal.terminalDidRequestDesktopNotification(
            title: "Build", body: "OK"
        )
        store.recordDesktopNotification(forTabID: tab.id)

        #expect(store.bellFeed.entries.first?.message == "Build: OK")
        #expect(store.bellFeed.entries.first?.seen == false)
        #expect(tab.unseenBellCount == 1)
    }
}
