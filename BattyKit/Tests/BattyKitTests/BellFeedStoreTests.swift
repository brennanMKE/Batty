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
        timestamp: Date = Date(),
        kind: BellFeedEntry.Kind = .bell
    ) -> BellFeedEntry {
        BellFeedEntry(
            timestamp: timestamp,
            windowID: UUID(),
            sessionID: sessionID,
            paneID: paneID,
            tabID: tabID,
            surfaceID: UUID(),
            message: nil,
            seen: seen,
            kind: kind
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

    @Test func bellFromFocusedTabRecordsButLeavesUnseenAlone() async {
        let store = AppStateStore()
        store.isBattyActiveProvider = { false }
        let session = store.sessions[0]
        let pane = session.tree.allPanes[0]
        let tab = pane.tabs[0]

        store.ringBell(in: tab)

        #expect(store.bellFeed.entries.count == 1)
        #expect(store.bellFeed.entries.first?.seen == true)
        #expect(tab.unseenBellCount == 0)
        #expect(pane.unseenBellCount == 0)
        #expect(session.unseenBellCount == 0)
    }

    @Test func bellFromUnfocusedTabIncrementsAllLevels() async {
        let store = AppStateStore()
        store.isBattyActiveProvider = { false }
        let focusedSession = store.sessions[0]
        let backgroundSession = store.addSession(title: "Background")!
        store.selectedSessionID = focusedSession.id

        let pane = backgroundSession.tree.allPanes[0]
        let tab = pane.tabs[0]

        store.ringBell(in: tab)

        #expect(store.bellFeed.entries.count == 1)
        #expect(store.bellFeed.entries.first?.seen == false)
        #expect(tab.unseenBellCount == 1)
        #expect(pane.unseenBellCount == 1)
        #expect(backgroundSession.unseenBellCount == 1)
        #expect(focusedSession.unseenBellCount == 0)
    }

    @Test func markBellSeenDecrementsAllLevels() async {
        let store = AppStateStore()
        store.isBattyActiveProvider = { false }
        let focusedSession = store.sessions[0]
        let backgroundSession = store.addSession()!
        store.selectedSessionID = focusedSession.id

        let pane = backgroundSession.tree.allPanes[0]
        let tab = pane.tabs[0]

        store.ringBell(in: tab)
        #expect(store.bellFeed.entries.first != nil)
        let entryID = store.bellFeed.entries[0].id

        store.markBellSeen(id: entryID)

        #expect(tab.unseenBellCount == 0)
        #expect(pane.unseenBellCount == 0)
        #expect(backgroundSession.unseenBellCount == 0)
    }

    @Test func markAllBellsSeenZerosCounters() async {
        let store = AppStateStore()
        store.isBattyActiveProvider = { false }
        let focusedSession = store.sessions[0]
        let backgroundSession = store.addSession()!
        store.selectedSessionID = focusedSession.id

        let pane = backgroundSession.tree.allPanes[0]
        let tab = pane.tabs[0]

        store.ringBell(in: tab)
        store.ringBell(in: tab)

        #expect(tab.unseenBellCount == 2)

        store.markAllBellsSeen()
        #expect(tab.unseenBellCount == 0)
        #expect(pane.unseenBellCount == 0)
        #expect(backgroundSession.unseenBellCount == 0)
    }

    @Test func desktopNotificationCarriesMessageThroughEntry() async {
        let store = AppStateStore()
        store.isBattyActiveProvider = { false }
        let session = store.sessions[0]
        let pane = session.tree.allPanes[0]
        let tab = pane.tabs[0]
        store.selectedSessionID = nil

        store.requestDesktopNotification(in: tab, title: "Build", body: "OK")

        #expect(store.bellFeed.entries.first != nil)
        #expect(store.bellFeed.entries.first?.message == "Build: OK")
        #expect(store.bellFeed.entries.first?.seen == false)
        #expect(tab.unseenBellCount == 1)
    }

    @Test func jumpToBellEntrySelectsSessionPaneAndTab() async {
        let store = AppStateStore()
        store.isBattyActiveProvider = { false }
        let focused = store.sessions[0]
        let target = store.addSession()!
        store.selectedSessionID = focused.id

        let pane = target.tree.allPanes[0]
        target.focusedPaneAnyKind.addTab()
        let secondaryTab = pane.tabs.last!
        pane.activeTabID = pane.tabs[0].id

        store.ringBell(in: secondaryTab)
        #expect(store.bellFeed.entries.first != nil)
        let entry = store.bellFeed.entries[0]

        store.jumpToBellEntry(entry)

        #expect(store.selectedSessionID == target.id)
        #expect(target.tree.focusedPaneID == pane.id)
        #expect(pane.activeTabID == secondaryTab.id)
        #expect(store.bellFeed.entries.isEmpty)
    }
}

private nonisolated final class AggregateChangeFlag: @unchecked Sendable {
    var fired = false
}

extension BellFeedStoreTests {

    private func track(_ read: @escaping () -> Void) -> AggregateChangeFlag {
        let flag = AggregateChangeFlag()
        withObservationTracking(read) { flag.fired = true }
        return flag
    }

    private func expectConsistent(_ store: BellFeedStore) {
        #expect(store.unseenCount == store.entries.filter { !$0.seen }.count)
        #expect(store.dueReminderSessionIDs == Set(store.entries.filter { $0.kind == .reminder && !$0.seen }.map(\.sessionID)))
    }

    @Test func collapsingARepeatedBellDoesNotNotifyUnseenCountReaders() {
        let store = BellFeedStore()
        let tab = UUID()
        store.recordOrCollapse(makeEntry(tabID: tab))
        let flag = track { _ = store.unseenCount }
        let outcome = store.recordOrCollapse(makeEntry(tabID: tab))
        guard case .collapsed = outcome else {
            Issue.record("expected a collapse, got \(outcome)")
            return
        }
        #expect(store.unseenCount == 1)
        #expect(!flag.fired)
    }

    @Test func aiSummaryArrivalDoesNotNotifyUnseenCountReaders() {
        let store = BellFeedStore()
        let first = makeEntry()
        store.record(first)
        store.record(makeEntry())
        let flag = track { _ = store.unseenCount }
        store.updateSummary("s", forEntryID: first.id)
        #expect(!flag.fired)
        #expect(store.unseenCount == 2)
    }

    @Test func recordingABellDoesNotNotifyDueReminderReaders() {
        let session = UUID()
        let store = BellFeedStore(entries: [makeEntry(sessionID: session, kind: .reminder)])
        #expect(store.dueReminderSessionIDs == [session])
        let flag = track { _ = store.dueReminderSessionIDs }
        store.record(makeEntry())
        #expect(!flag.fired)
        #expect(store.dueReminderSessionIDs == [session])
    }

    @Test func markingSeenUpdatesUnseenCount() {
        let store = BellFeedStore()
        let a = makeEntry(), b = makeEntry(), c = makeEntry()
        store.record(makeEntry(seen: true))
        store.record(a); store.record(b); store.record(c)
        #expect(store.unseenCount == 3)
        let flag = track { _ = store.unseenCount }
        _ = store.markSeen(id: a.id)
        #expect(flag.fired)
        #expect(store.unseenCount == 2)
        let again = track { _ = store.unseenCount }
        _ = store.markSeen(id: a.id)
        #expect(!again.fired)
        #expect(store.unseenCount == 2)
        store.markAllSeen()
        #expect(store.unseenCount == 0)
    }

    @Test func dueReminderSessionIDsTracksReminderEntries() {
        let a = UUID(), b = UUID(), c = UUID()
        let store = BellFeedStore()
        let reminderA = makeEntry(sessionID: a, kind: .reminder)
        store.record(reminderA)
        store.record(makeEntry(sessionID: b, kind: .reminder))
        store.record(makeEntry(sessionID: c))
        #expect(store.dueReminderSessionIDs == [a, b])
        _ = store.markSeen(id: reminderA.id)
        #expect(store.dueReminderSessionIDs == [b])
        store.removeReminderEntries(forSessionID: b)
        #expect(store.dueReminderSessionIDs == [])

        let seeded = BellFeedStore(entries: [makeEntry(sessionID: a, kind: .reminder)])
        #expect(seeded.dueReminderSessionIDs == [a])
    }

    @Test func aggregatesMatchAScanAfterEveryMutator() {
        let store = BellFeedStore()
        let tab = UUID()
        let session = UUID()
        let first = makeEntry(tabID: tab)
        store.record(first)
        expectConsistent(store)
        store.recordOrCollapse(makeEntry(tabID: tab))
        expectConsistent(store)
        store.recordOrCollapse(makeEntry())
        expectConsistent(store)
        let reminder = makeEntry(sessionID: session, kind: .reminder)
        store.record(reminder)
        expectConsistent(store)
        store.updateSummary("s", forEntryID: first.id)
        expectConsistent(store)
        _ = store.markSeen(id: first.id)
        expectConsistent(store)
        store.removeEntries(matchingTabIDs: [tab])
        expectConsistent(store)
        store.removeReminderEntries(forSessionID: session)
        expectConsistent(store)
        store.record(makeEntry(sessionID: session, kind: .reminder))
        var replaced = store.entries[0]
        replaced.seen = true
        store.entries[0] = replaced
        expectConsistent(store)
        store.markAllSeen()
        expectConsistent(store)
        for _ in 0...BellFeedStore.cap {
            store.record(makeEntry(sessionID: session, kind: .reminder))
        }
        expectConsistent(store)
    }
}
