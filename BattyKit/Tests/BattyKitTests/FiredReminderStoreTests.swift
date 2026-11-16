// FiredReminderStoreTests.swift

import Foundation
import Testing
@testable import BattyKit

@MainActor
struct FiredReminderStoreTests {

    private func makeItem(
        sessionID: UUID = UUID(),
        note: String? = nil,
        firedAt: Date = Date(timeIntervalSince1970: 1_000),
        seen: Bool = false
    ) -> FiredReminder {
        FiredReminder(
            id: UUID(),
            sessionID: sessionID,
            windowID: UUID(),
            note: note,
            createdAt: firedAt.addingTimeInterval(-300),
            dueAt: firedAt,
            firedAt: firedAt,
            seen: seen
        )
    }

    private func track(_ read: @escaping () -> Void) -> FiredAggregateChangeFlag {
        let flag = FiredAggregateChangeFlag()
        withObservationTracking(read) { flag.fired = true }
        return flag
    }

    private func expectConsistent(_ store: FiredReminderStore) {
        #expect(store.unseenCount == store.items.filter { !$0.seen }.count)
        #expect(store.readCount == store.items.filter(\.seen).count)
        #expect(store.unseenSessionIDs == Set(store.items.filter { !$0.seen }.map(\.sessionID)))
    }

    @Test func recordPrependsNewestFirst() {
        let store = FiredReminderStore()
        let older = makeItem()
        let newer = makeItem()
        store.record(older)
        store.record(newer)
        #expect(store.items.map(\.id) == [newer.id, older.id])
    }

    @Test func recordReplacesTheSameSessionsItem() {
        let store = FiredReminderStore()
        let session = UUID()
        let other = makeItem()
        let first = makeItem(sessionID: session, note: "first", seen: true)
        let second = makeItem(sessionID: session, note: "second")
        store.record(first)
        store.record(other)
        store.record(second)
        #expect(store.items.map(\.id) == [second.id, other.id])
        #expect(store.item(forSessionID: session) == second)
        expectConsistent(store)
    }

    @Test func markSeenWithNoMatchDoesNotNotify() {
        let store = FiredReminderStore()
        let read = makeItem(seen: true)
        store.record(read)
        let flag = track { _ = store.items }
        #expect(store.markSeen(sessionID: UUID()) == false)
        #expect(store.markSeen(id: UUID()) == false)
        #expect(store.markSeen(sessionID: read.sessionID) == false, "already read")
        #expect(store.markSeen(id: read.id) == false, "already read")
        #expect(!flag.fired)
    }

    @Test func removeWithNoMatchDoesNotNotify() {
        let store = FiredReminderStore()
        store.record(makeItem())
        let flag = track { _ = store.items }
        #expect(store.remove(sessionID: UUID()) == nil)
        #expect(store.remove(id: UUID()) == nil)
        #expect(!flag.fired)
    }

    @Test func markAllSeenReturnsOnlyTouchedItems() {
        let store = FiredReminderStore()
        let read = makeItem(seen: true)
        let unread = makeItem()
        store.record(read)
        store.record(unread)
        let touched = store.markAllSeen()
        #expect(touched.map(\.id) == [unread.id])
        #expect(store.items.allSatisfy { $0.seen })
        #expect(store.items.count == 2)
        let flag = track { _ = store.items }
        #expect(store.markAllSeen().isEmpty)
        #expect(!flag.fired)
    }

    @Test func removeReadEntriesKeepsUnreadItems() {
        let store = FiredReminderStore()
        let read = makeItem(seen: true)
        let unread = makeItem()
        store.record(read)
        store.record(unread)
        let removed = store.removeReadEntries()
        #expect(removed.map(\.id) == [read.id])
        #expect(store.items.map(\.id) == [unread.id])
        expectConsistent(store)
    }

    @Test func removeReadEntriesWithNothingReadDoesNotNotify() {
        let store = FiredReminderStore()
        store.record(makeItem())
        let flag = track { _ = store.items }
        #expect(store.removeReadEntries().isEmpty)
        #expect(!flag.fired)
    }

    @Test func unseenSessionIDsTracksOnlyUnreadItems() {
        let a = UUID(), b = UUID(), c = UUID()
        let store = FiredReminderStore()
        store.record(makeItem(sessionID: a))
        store.record(makeItem(sessionID: b))
        store.record(makeItem(sessionID: c, seen: true))
        #expect(store.unseenSessionIDs == [a, b])
        #expect(store.markSeen(sessionID: a))
        #expect(store.unseenSessionIDs == [b])
        let flag = track { _ = store.unseenSessionIDs }
        store.remove(sessionID: c)
        #expect(!flag.fired, "removing a read item leaves the unread set unchanged")
        store.remove(sessionID: b)
        #expect(store.unseenSessionIDs == [])
    }

    @Test func aggregatesMatchAScanAfterEveryMutator() {
        let store = FiredReminderStore()
        let session = UUID()
        let first = makeItem(sessionID: session)
        store.record(first)
        expectConsistent(store)
        store.record(makeItem())
        expectConsistent(store)
        store.record(makeItem(sessionID: session, seen: true))
        expectConsistent(store)
        let third = makeItem()
        store.record(third)
        _ = store.markSeen(id: third.id)
        expectConsistent(store)
        _ = store.markSeen(sessionID: session)
        expectConsistent(store)
        store.remove(id: third.id)
        expectConsistent(store)
        store.record(makeItem())
        store.markAllSeen()
        expectConsistent(store)
        store.record(makeItem())
        store.removeReadEntries()
        expectConsistent(store)
        store.remove(sessionID: store.items[0].sessionID)
        expectConsistent(store)
    }
}

private nonisolated final class FiredAggregateChangeFlag: @unchecked Sendable {
    var fired = false
}
