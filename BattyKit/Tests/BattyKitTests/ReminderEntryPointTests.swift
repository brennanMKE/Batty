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

    @Test func newDraftDefaultsTomorrowPickerToRememberedTime() {
        let remembered = ReminderTime(hour: 7, minute: 15)
        var draft = ReminderDraft(tomorrow: remembered)
        draft.choice = .tomorrow
        #expect(draft.spec == .tomorrow(hour: 7, minute: 15))
        var fresh = ReminderDraft(editing: nil, now: ReminderFixture.anchor, tomorrow: remembered)
        fresh.choice = .tomorrow
        #expect(fresh.spec == .tomorrow(hour: 7, minute: 15))
    }

    @Test func editingDraftKeepsTheReminderOwnTime() {
        let reminder = SessionReminder(
            createdAt: ReminderFixture.anchor,
            target: .wallClock(DateComponents(year: 2026, month: 10, day: 15, hour: 10, minute: 0)))
        let draft = ReminderDraft(editing: reminder, now: ReminderFixture.anchor, tomorrow: ReminderTime(hour: 7, minute: 15))
        #expect(draft.choice == .tomorrow)
        #expect(draft.spec == .tomorrow(hour: 10, minute: 0))
    }

    @Test func editingAnInstantReminderKeepsTheRememberedTomorrowTime() {
        let now = ReminderFixture.anchor
        let reminder = SessionReminder(createdAt: now, target: .instant(now.addingTimeInterval(600)))
        let draft = ReminderDraft(editing: reminder, now: now, tomorrow: ReminderTime(hour: 7, minute: 15))
        #expect(draft.choice == .custom)
        #expect(draft.tomorrowHour == 7)
        #expect(draft.tomorrowMinute == 15)
    }

    @Test func tomorrowMenuTitleUsesRememberedTime() {
        let title = ReminderActions.tomorrowTitle(
            ReminderTime(hour: 8, minute: 30), calendar: ReminderFixture.calendar(), locale: Locale(identifier: "en_US"))
        #expect(title.replacingOccurrences(of: "\u{202F}", with: " ") == "Tomorrow at 8:30 AM")
    }

    @Test func thePaletteTomorrowEntryUsesTheRememberedTime() throws {
        SettingsPreference.storeReminderTomorrowTime(ReminderTime(hour: 8, minute: 30), defaults: testDefaults.defaults)
        let store = AppStateStore(
            preferences: testDefaults.defaults,
            reminderClock: TestClock(now: ReminderFixture.anchor),
            reminderCalendar: { ReminderFixture.calendar() })
        let session = store.sessions[0]
        store.selectedSessionID = session.id
        let entry = try #require(CommandPaletteView(isPresented: .constant(true), store: store)
            .allCommands.first { $0.id == "extra:remind:tomorrow" })
        #expect(entry.title.hasPrefix("Remind Me Tomorrow at "))
        #expect(entry.title.contains("8:30"))
        entry.action()
        let reminder = try #require(session.reminder)
        #expect(reminder.target == .wallClock(DateComponents(year: 2026, month: 10, day: 15, hour: 8, minute: 30)))
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
