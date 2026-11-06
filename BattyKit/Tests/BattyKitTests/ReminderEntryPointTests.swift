// ReminderEntryPointTests.swift

import Foundation
import SwiftUI
import Testing
@testable import BattyKit

/// The sheet's draft rules and the Command Palette's Remind Me entries,
/// exercised against the production types.
@MainActor
struct ReminderEntryPointTests {
    private let testDefaults = TestDefaults()

    // MARK: - Draft

    @Test func aNewDraftSelectsFifteenMinutesAndIsReadyToSet() {
        let draft = ReminderDraft()
        #expect(draft.choice == .preset(15))
        #expect(draft.spec == .after(minutes: 15))
        #expect(draft.canSet)
    }

    @Test func customNeedsBetweenOneMinuteAndSevenDays() {
        var draft = ReminderDraft()
        draft.choice = .custom
        #expect(!draft.canSet, "0 h 0 m is not a duration")
        draft.minutes = 1
        #expect(draft.spec == .after(minutes: 1))
        #expect(draft.canSet)
        draft.hours = 168
        draft.minutes = 0
        #expect(draft.spec == .after(minutes: 10_080))
        #expect(draft.canSet)
        draft.minutes = 1
        #expect(!draft.canSet, "7 days and a minute is over the limit")
        draft.hours = 169
        draft.minutes = 0
        #expect(!draft.canSet)
        draft.hours = 1
        draft.minutes = 75
        #expect(!draft.canSet, "minutes are 0-59")
    }

    @Test func tomorrowUsesTheEditedTimeAndDefaultsToNineAM() {
        var draft = ReminderDraft()
        draft.choice = .tomorrow
        #expect(draft.spec == .tomorrow(hour: 9, minute: 0))
        draft.tomorrowHour = 17
        draft.tomorrowMinute = 45
        #expect(draft.spec == .tomorrow(hour: 17, minute: 45))
    }

    @Test func editingAnInstantReminderReopensOnCustomWithTheTimeLeft() {
        let now = ReminderFixture.anchor
        let reminder = SessionReminder(
            createdAt: now.addingTimeInterval(-600),
            target: .instant(now.addingTimeInterval(95 * 60)),
            note: "ship it")
        let draft = ReminderDraft(editing: reminder, now: now)
        #expect(draft.choice == .custom)
        #expect(draft.hours == 1)
        #expect(draft.minutes == 35)
        #expect(draft.note == "ship it")
    }

    @Test func editingATomorrowReminderReopensOnTomorrowAtItsTime() {
        let reminder = SessionReminder(
            createdAt: ReminderFixture.anchor,
            target: .wallClock(DateComponents(year: 2026, month: 10, day: 15, hour: 7, minute: 30)))
        let draft = ReminderDraft(editing: reminder, now: ReminderFixture.anchor)
        #expect(draft.choice == .tomorrow)
        #expect(draft.spec == .tomorrow(hour: 7, minute: 30))
        #expect(draft.note.isEmpty)
    }

    @Test func aReminderAlreadyPastDueReopensWithAtLeastOneMinute() {
        let now = ReminderFixture.anchor
        let reminder = SessionReminder(createdAt: now.addingTimeInterval(-3600), target: .instant(now.addingTimeInterval(-30)))
        let draft = ReminderDraft(editing: reminder, now: now)
        #expect(draft.canSet)
        #expect(draft.hours * 60 + draft.minutes == 1)
    }

    // MARK: - Row value

    @Test func theRowValueCarriesTheReminderStateAfterTheExistingParts() {
        let session = SessionRuntime(title: "x")
        session.unseenBellCount = 2
        #expect(SessionSidebarView.rowAccessibilityValue(for: session, isSelected: false, reminder: "reminder due")
                == "unselected, 2 unseen, reminder due")
        #expect(SessionSidebarView.rowAccessibilityValue(for: session, isSelected: true) == "selected, 2 unseen")
    }

    // MARK: - Palette

    private func makeStore(manualClock: Bool = false) -> AppStateStore {
        AppStateStore(
            preferences: testDefaults.defaults,
            reminderClock: manualClock ? ManualSchedulingClock(start: ReminderFixture.anchor) : TestClock(now: ReminderFixture.anchor))
    }

    @Test func thePaletteOffersTheRemindMeEntriesButNotEditOrCancelUntilOnePends() {
        let store = makeStore()
        let ids = Set(CommandPaletteView(isPresented: .constant(true), store: store).allCommands.map(\.id))
        #expect(ids.isSuperset(of: ["extra:remind:sheet", "extra:remind:5", "extra:remind:15", "extra:remind:30", "extra:remind:60", "extra:remind:tomorrow"]))
        #expect(!ids.contains("extra:remind:edit"))
        #expect(!ids.contains("extra:remind:cancel"))
        #expect(!ids.contains { $0.hasPrefix("uitest:") })
    }

    @Test func aPaletteEntryTitledInThirtyMinutesSetsAThirtyMinuteReminderOnTheSelectedSession() throws {
        let store = makeStore()
        store.addSession(title: "other")
        store.selectedSessionID = store.sessions[0].id
        let selected = store.sessions[0]
        let view = CommandPaletteView(isPresented: .constant(true), store: store)

        try #require(view.allCommands.first { $0.id == "extra:remind:30" }).action()

        let reminder = try #require(selected.reminder)
        #expect(reminder.target == .instant(ReminderFixture.anchor.addingTimeInterval(30 * 60)))
        #expect(reminder.note == nil)
        #expect(store.sessions[1].reminder == nil)
    }

    @Test func editAndCancelAppearOnceAReminderPendsAndCancelClearsIt() throws {
        let store = makeStore()
        let session = store.sessions[0]
        store.setReminder(.after(minutes: 5), forSessionID: session.id)
        let view = CommandPaletteView(isPresented: .constant(true), store: store)
        let commands = view.allCommands

        #expect(commands.contains { $0.id == "extra:remind:edit" })
        try #require(commands.first { $0.id == "extra:remind:cancel" }).action()
        #expect(session.reminder == nil)
    }

    @Test func theSheetEntryOpensTheSheetForTheSelectedSession() throws {
        let store = makeStore()
        let view = CommandPaletteView(isPresented: .constant(true), store: store)
        try #require(view.allCommands.first { $0.id == "extra:remind:sheet" }).action()
        #expect(store.windows[0].reminderSheetSessionID == store.sessions[0].id)
    }

    @Test func theUITestClockEntriesExistOnlyUnderTheManualClockAndAdvanceIt() throws {
        let store = makeStore(manualClock: true)
        let view = CommandPaletteView(isPresented: .constant(true), store: store)
        let clock = try #require(store.reminderScheduler.manualClock)
        let before = clock.now
        try #require(view.allCommands.first { $0.id == "uitest:reminderClock:300" }).action()
        #expect(clock.now.timeIntervalSince(before) == 300)
    }
}
