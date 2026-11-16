// RemindersListModelTests.swift

import Foundation
import Testing
@testable import BattyKit

@MainActor
@Suite("RemindersListModel")
struct RemindersListModelTests {
    private let calendar = ReminderFixture.calendar()
    private let anchor = ReminderFixture.anchor
    private let testDefaults = TestDefaults()

    private func fired(
        session: UUID,
        id: UUID = UUID(),
        minutesAgo: Double,
        seen: Bool = false
    ) -> FiredReminder {
        let firedAt = anchor.addingTimeInterval(-minutesAgo * 60)
        return FiredReminder(
            id: id, sessionID: session, windowID: UUID(), note: nil,
            createdAt: firedAt.addingTimeInterval(-300), dueAt: firedAt, firedAt: firedAt, seen: seen)
    }

    private func pending(inMinutes minutes: Double, id: UUID = UUID()) -> SessionReminder {
        SessionReminder(id: id, createdAt: anchor, target: .instant(anchor.addingTimeInterval(minutes * 60)))
    }

    private func session(_ title: String, id: UUID = UUID(), reminder: SessionReminder? = nil) -> RemindersSessionInput {
        RemindersSessionInput(id: id, title: title, reminder: reminder)
    }

    private func model(fired: [FiredReminder] = [], sessions: [RemindersSessionInput] = []) -> RemindersListModel {
        RemindersListModel(fired: fired, sessions: sessions, calendar: calendar)
    }

    @Test func dueComesBeforeUpcomingAndEachIsOrdered() {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        let older = fired(session: a, minutesAgo: 10)
        let newer = fired(session: b, minutesAgo: 2)
        let list = model(
            fired: [older, newer],
            sessions: [
                session("A", id: a), session("B", id: b),
                session("C", id: c, reminder: pending(inMinutes: 60)),
                session("D", id: d, reminder: pending(inMinutes: 5)),
            ])
        #expect(list.rowIDs == [.due(newer.id), .due(older.id), .upcoming(d), .upcoming(c)])
        #expect(list.due.map(\.sessionTitle) == ["B", "A"])
        #expect(list.upcoming.map(\.sessionTitle) == ["D", "C"])
    }

    @Test func upcomingListsEveryPendingReminderAcrossWindows() throws {
        let store = AppStateStore(preferences: testDefaults.defaults, reminderClock: TestClock(now: anchor))
        let first = store.sessions[0]
        let other = store.openWindowRuntime(for: WindowID()).addSession(title: "Other")
        try #require(store.setReminder(.after(minutes: 30), forSessionID: first.id) != nil)
        try #require(store.setReminder(.after(minutes: 5), forSessionID: other.id) != nil)
        let list = RemindersListModel.current(in: store)
        #expect(list.upcoming.map(\.sessionID) == [other.id, first.id])
        #expect(list.due.isEmpty)
    }

    @Test func anUnresolvableDueDateSortsLast() {
        let impossible = SessionReminder(
            createdAt: anchor, target: .wallClock(DateComponents(year: 1_000_000_000_000, month: 1, day: 1, hour: 9, minute: 0)))
        let a = UUID(), b = UUID()
        let list = model(sessions: [
            session("A", id: a, reminder: impossible),
            session("B", id: b, reminder: pending(inMinutes: 5)),
        ])
        #expect(list.rowIDs == [.upcoming(b), .upcoming(a)])
        #expect(list.upcoming.count == 2)
        #expect(list.upcoming.last?.dueAt == nil)
    }

    @Test func toolbarGlyphIsPlainWithNoReminders() {
        let list = model(sessions: [session("A")])
        #expect(list.glyph == .idle)
        #expect(list.glyph.systemImage == "alarm")
        #expect(!list.glyph.usesAccent)
        #expect(list.isEmpty)
    }

    @Test func toolbarGlyphRingsOnlyForUnreadFired() {
        let a = UUID(), b = UUID()
        let item = fired(session: a, minutesAgo: 1)
        let ringing = model(fired: [item], sessions: [session("A", id: a), session("B", id: b, reminder: pending(inMinutes: 5))])
        #expect(ringing.glyph == .ringing)
        #expect(ringing.glyph.systemImage == "alarm.waves.left.and.right.fill")
        #expect(ringing.glyph.usesAccent)
        var read = item
        read.seen = true
        let filled = model(fired: [read], sessions: [session("A", id: a), session("B", id: b, reminder: pending(inMinutes: 5))])
        #expect(filled.glyph == .filled)
    }

    @Test func toolbarGlyphIsFilledForPendingOrReadFired() {
        let pendingOnly = model(sessions: [session("A", reminder: pending(inMinutes: 5))])
        #expect(pendingOnly.glyph == .filled)
        #expect(pendingOnly.glyph.systemImage == "alarm.fill")
        #expect(!pendingOnly.glyph.usesAccent)
        let a = UUID()
        let readOnly = model(fired: [fired(session: a, minutesAgo: 1, seen: true)], sessions: [session("A", id: a)])
        #expect(readOnly.glyph == .filled)
        #expect(!readOnly.glyph.usesAccent)
    }

    @Test func toolbarValueSummarizesCounts() {
        let a = UUID(), b = UUID()
        let twoPending = [session("C", reminder: pending(inMinutes: 5)), session("D", reminder: pending(inMinutes: 9))]
        #expect(model().accessibilityValue == "none")
        #expect(model(sessions: twoPending).accessibilityValue == "2 upcoming")
        #expect(model(fired: [fired(session: a, minutesAgo: 1, seen: true)], sessions: [session("A", id: a)] + twoPending)
            .accessibilityValue == "1 due, 2 upcoming")
        #expect(model(fired: [fired(session: a, minutesAgo: 1)], sessions: [session("A", id: a)] + twoPending)
            .accessibilityValue == "1 unread due, 2 upcoming")
        #expect(model(
            fired: [fired(session: a, minutesAgo: 1), fired(session: b, minutesAgo: 2, seen: true)],
            sessions: [session("A", id: a), session("B", id: b)]
        ).accessibilityValue == "2 due, 1 unread")
    }

    @Test func initialSelectionPrefersTheFirstUnreadDueRow() {
        let a = UUID(), b = UUID(), c = UUID()
        let readNewer = fired(session: a, minutesAgo: 1, seen: true)
        let unreadOlder = fired(session: b, minutesAgo: 5)
        let sessions = [session("A", id: a), session("B", id: b), session("C", id: c, reminder: pending(inMinutes: 5))]
        #expect(model(fired: [readNewer, unreadOlder], sessions: sessions).initialSelection == .due(unreadOlder.id))
        var readOlder = unreadOlder
        readOlder.seen = true
        #expect(model(fired: [readNewer, readOlder], sessions: sessions).initialSelection == .due(readNewer.id))
        #expect(model(sessions: sessions).initialSelection == .upcoming(c))
        #expect(model().initialSelection == nil)
    }

    @Test func remindAgainIsDisabledWhenANewerReminderIsPending() {
        let a = UUID(), b = UUID()
        let itemA = fired(session: a, minutesAgo: 1)
        let itemB = fired(session: b, minutesAgo: 2)
        let list = model(
            fired: [itemA, itemB],
            sessions: [session("A", id: a, reminder: pending(inMinutes: 5)), session("B", id: b)])
        #expect(list.due.first { $0.fired.id == itemA.id }?.canRemindAgain == false)
        #expect(list.due.first { $0.fired.id == itemB.id }?.canRemindAgain == true)
    }

    @Test func arrowsMoveAcrossDueThenUpcomingAndWrap() {
        let a = UUID(), c = UUID(), d = UUID()
        let item = fired(session: a, minutesAgo: 1)
        let list = model(
            fired: [item],
            sessions: [session("A", id: a), session("C", id: c, reminder: pending(inMinutes: 5)),
                       session("D", id: d, reminder: pending(inMinutes: 9))])
        #expect(list.moved(from: .due(item.id), by: 1) == .upcoming(c))
        #expect(list.moved(from: .upcoming(d), by: 1) == .due(item.id))
        #expect(list.moved(from: .due(item.id), by: -1) == .upcoming(d))
        #expect(list.moved(from: nil, by: 1) == .due(item.id))
        #expect(list.moved(from: nil, by: -1) == .upcoming(d))
        #expect(list.moved(from: .upcoming(UUID()), by: 1) == .due(item.id))
        #expect(model().moved(from: nil, by: 1) == nil)
    }

    @Test func selectionAfterRemovalMovesToTheRowThatTookItsPlace() {
        let a = UUID(), b = UUID(), c = UUID()
        let pa = pending(inMinutes: 1), pb = pending(inMinutes: 2), pc = pending(inMinutes: 3)
        let full = model(sessions: [session("A", id: a, reminder: pa), session("B", id: b, reminder: pb), session("C", id: c, reminder: pc)])
        let withoutMiddle = model(sessions: [session("A", id: a, reminder: pa), session("B", id: b), session("C", id: c, reminder: pc)])
        #expect(RemindersListModel.selection(.upcoming(b), after: full.rowIDs, in: withoutMiddle) == .upcoming(c))
        #expect(RemindersListModel.selection(.upcoming(a), after: full.rowIDs, in: withoutMiddle) == .upcoming(a))
        let withoutLast = model(sessions: [session("A", id: a, reminder: pa), session("B", id: b, reminder: pb), session("C", id: c)])
        #expect(RemindersListModel.selection(.upcoming(c), after: full.rowIDs, in: withoutLast) == .upcoming(b))
        #expect(RemindersListModel.selection(.upcoming(a), after: full.rowIDs, in: model()) == nil)
    }

    @Test func keysAfterRemindAgainActOnTheRowsAsTheyAreNow() throws {
        let a = UUID(), b = UUID()
        let item = fired(session: a, minutesAgo: 1)
        let later = pending(inMinutes: 60)
        let before = model(fired: [item], sessions: [session("A", id: a), session("B", id: b, reminder: later)])
        let after = model(sessions: [session("A", id: a, reminder: pending(inMinutes: 15)), session("B", id: b, reminder: later)])
        let dueRow = try #require(before.due.first)

        let selection = RemindersListModel.selection(dueRow.id, after: before.rowIDs, in: after)
        #expect(selection == .upcoming(a))
        #expect(after.action(for: .down, selection: selection) == .select(.upcoming(b)))
        // The rows from before Remind Again send Down back to the removed Due row.
        #expect(before.action(for: .down, selection: selection) == .select(dueRow.id))
        let beta = try #require(after.upcoming.first { $0.sessionID == b })
        #expect(after.action(for: .edit, selection: .upcoming(b)) == .edit(beta))
    }

    @Test func keysActOnTheSelectedDueRow() throws {
        let a = UUID(), b = UUID()
        let item = fired(session: a, minutesAgo: 1)
        let blocked = fired(session: b, minutesAgo: 2)
        let list = model(
            fired: [item, blocked],
            sessions: [session("A", id: a), session("B", id: b, reminder: pending(inMinutes: 5))])
        let row = try #require(list.due.first { $0.fired.id == item.id })
        let blockedRow = try #require(list.due.first { $0.fired.id == blocked.id })
        #expect(list.action(for: .remindAgain, selection: row.id) == .remindAgain(row))
        #expect(list.action(for: .delete, selection: row.id) == .done(row))
        #expect(list.action(for: .open, selection: row.id) == .open(a))
        #expect(list.action(for: .edit, selection: row.id) == nil)
        #expect(list.action(for: .remindAgain, selection: blockedRow.id) == nil)
        #expect(list.action(for: .down, selection: row.id) == .select(blockedRow.id))
    }

    @Test func keysActOnTheSelectedUpcomingRow() throws {
        let c = UUID()
        let list = model(sessions: [session("C", id: c, reminder: pending(inMinutes: 5))])
        let row = try #require(list.upcoming.first)
        #expect(list.action(for: .edit, selection: row.id) == .edit(row))
        #expect(list.action(for: .delete, selection: row.id) == .cancel(row))
        #expect(list.action(for: .open, selection: row.id) == .open(c))
        #expect(list.action(for: .remindAgain, selection: row.id) == nil)
    }

    @Test func keysDoNothingWithoutASelection() {
        let list = model(sessions: [session("C", reminder: pending(inMinutes: 5))])
        for key in [RemindersListKey.open, .delete, .edit, .remindAgain] {
            #expect(list.action(for: key, selection: nil) == nil)
            #expect(list.action(for: key, selection: .upcoming(UUID())) == nil)
        }
        #expect(list.action(for: .up, selection: nil) == .select(list.upcoming[0].id))
        #expect(model().action(for: .down, selection: nil) == nil)
    }

    @Test func toggleActsInTheKeyWindowOrTheWindowShowingThePopover() {
        #expect(RemindersPopoverToggle.shouldHandle(isKeyWindow: true, isShown: false))
        #expect(RemindersPopoverToggle.shouldHandle(isKeyWindow: false, isShown: true))
        #expect(!RemindersPopoverToggle.shouldHandle(isKeyWindow: false, isShown: false))
    }
}
