// ReminderEntryPointTests.swift

import Foundation
import SwiftUI
import Testing
@testable import BattyKit

/// The Command Palette's Remind Me entries, exercised against the
/// production types.
@MainActor
struct ReminderEntryPointTests {
    private let testDefaults = TestDefaults()

    // MARK: - Menu titles

    @Test func tomorrowMenuTitleUsesRememberedTime() {
        let title = ReminderActions.tomorrowTitle(
            ReminderTime(hour: 8, minute: 30), calendar: ReminderFixture.calendar(), locale: Locale(identifier: "en_US"))
        #expect(title.replacingOccurrences(of: "\u{202F}", with: " ") == "Tomorrow at 8:30 AM")
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

    @Test func cancelIsThePaletteOnlyOtherReminderRowWhilePending() throws {
        let store = makeStore()
        let session = store.sessions[0]
        let before = CommandPaletteView(isPresented: .constant(true), store: store).allCommands
        #expect(!before.contains { $0.id == "extra:remind:cancel" })
        store.setReminder(.after(minutes: 5), note: "x", forSessionID: session.id)
        let commands = CommandPaletteView(isPresented: .constant(true), store: store).allCommands
        let reminderIDs = commands.map(\.id).filter { $0.lowercased().contains("remind") }
        #expect(Set(reminderIDs) == ["action:remindMe", "extra:remind:cancel"])
        try #require(commands.first { $0.id == "extra:remind:cancel" }).action()
        #expect(session.reminder == nil)
    }

    @Test func thePaletteRemindMeRowOpensTheBarSheetForTheSelectedSession() throws {
        let store = makeStore()
        store.addSession(title: "other")
        store.selectedSessionID = store.sessions[1].id
        var deferred: [@MainActor () -> Void] = []
        let view = CommandPaletteView(isPresented: .constant(true), store: store, afterDismiss: { deferred.append($0) })
        let row = try #require(view.allCommands.first { $0.id == "action:remindMe" })
        #expect(row.title == "Remind Me…")
        row.action()
        #expect(store.windows[0].reminderBarSessionID == nil, "the bar waits for the palette to close")
        #expect(deferred.count == 1)
        deferred.forEach { $0() }
        #expect(store.windows[0].reminderBarSessionID == store.sessions[1].id)
    }

    @Test func theRemindMeDispatchOpensTheBarForTheSelectedSession() {
        let store = makeStore()
        store.addSession(title: "other")
        store.selectedSessionID = store.sessions[1].id
        CommandPaletteView(isPresented: .constant(true), store: store).dispatch(.remindMe)
        #expect(store.windows[0].reminderBarSessionID == store.sessions[1].id)
    }

    @Test func thePaletteOffersRemindMeAndNoTextlessReminderRows() {
        let store = makeStore()
        let ids = Set(CommandPaletteView(isPresented: .constant(true), store: store).allCommands.map(\.id))
        #expect(ids.contains("action:remindMe"))
        for gone in ["sheet", "5", "15", "30", "60", "tomorrow", "edit"] {
            #expect(!ids.contains("extra:remind:\(gone)"))
        }
    }

    @Test func theUITestClockEntriesExistOnlyUnderTheManualClockAndAdvanceIt() throws {
        let store = makeStore(manualClock: true)
        let view = CommandPaletteView(isPresented: .constant(true), store: store)
        let clock = try #require(store.reminderScheduler.manualClock)
        let before = clock.now
        try #require(view.allCommands.first { $0.id == "uitest:reminderClock:300" }).action()
        #expect(clock.now.timeIntervalSince(before) == 300)
    }

    // MARK: - Menu gate

    @Test func remindMeIsDeclinedWhileTheWindowHasAnAttachedSheet() throws {
        let store = makeStore()
        let window = store.windows[0]
        let session = try #require(window.selectedSession)
        ReminderActions.openBar(for: session, in: window, windowHasAttachedSheet: true)
        #expect(window.reminderBarSessionID == nil)
        ReminderActions.openBar(for: session, in: window, windowHasAttachedSheet: false)
        #expect(window.reminderBarSessionID == session.id)
    }

    @Test func editReminderIsDeclinedWhileTheWindowHasAnAttachedSheet() throws {
        let store = makeStore()
        let window = store.windows[0]
        let session = try #require(window.selectedSession)
        store.setReminder(.after(minutes: 5), note: "x", forSessionID: session.id)
        #expect(session.reminder != nil)
        ReminderActions.openBar(for: session, in: window, windowHasAttachedSheet: true)
        #expect(window.reminderBarSessionID == nil)
        ReminderActions.openBar(for: session, in: window, windowHasAttachedSheet: false)
        #expect(window.reminderBarSessionID == session.id)
    }

    @Test func windowHasAttachedSheetIsFalseForAWindowWithNoRegisteredNSWindow() {
        let store = makeStore()
        #expect(store.windowHasAttachedSheet(store.windows[0].id) == false)
    }
}
