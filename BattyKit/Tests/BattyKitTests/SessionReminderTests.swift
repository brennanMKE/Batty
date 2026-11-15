// SessionReminderTests.swift

import Foundation
import Testing
@testable import BattyKit

@MainActor
struct SessionReminderTests {
    private let calendar = ReminderFixture.calendar()

    // MARK: - Duration bounds

    @Test func durationBoundsAreOneMinuteThroughSevenDays() {
        #expect(ReminderSpec.after(minutes: 0).makeReminder(now: ReminderFixture.anchor, calendar: calendar, note: nil) == nil)
        #expect(ReminderSpec.after(minutes: -5).makeReminder(now: ReminderFixture.anchor, calendar: calendar, note: nil) == nil)
        #expect(ReminderSpec.after(minutes: 7 * 24 * 60 + 1).makeReminder(now: ReminderFixture.anchor, calendar: calendar, note: nil) == nil)
        let shortest = ReminderSpec.after(minutes: 1).makeReminder(now: ReminderFixture.anchor, calendar: calendar, note: nil)
        let longest = ReminderSpec.after(minutes: 7 * 24 * 60).makeReminder(now: ReminderFixture.anchor, calendar: calendar, note: nil)
        #expect(shortest?.target == .instant(ReminderFixture.anchor.addingTimeInterval(60)))
        #expect(longest?.target == .instant(ReminderFixture.anchor.addingTimeInterval(7 * 86_400)))
    }

    @Test func tomorrowTimeOutsideTheClockIsRejected() {
        #expect(ReminderSpec.tomorrow(hour: 24, minute: 0).makeReminder(now: ReminderFixture.anchor, calendar: calendar, note: nil) == nil)
        #expect(ReminderSpec.tomorrow(hour: 9, minute: 60).makeReminder(now: ReminderFixture.anchor, calendar: calendar, note: nil) == nil)
        #expect(ReminderSpec.tomorrow(hour: 23, minute: 59).makeReminder(now: ReminderFixture.anchor, calendar: calendar, note: nil) != nil)
    }

    // MARK: - Tomorrow

    @Test func tomorrowIsTheNextCalendarDayAtTheChosenTime() throws {
        let reminder = try #require(ReminderSpec.tomorrow(hour: 9, minute: 0)
            .makeReminder(now: ReminderFixture.anchor, calendar: calendar, note: nil))
        #expect(reminder.fireDate(calendar: calendar) == ReminderFixture.date(2026, 10, 15, 9, 0))
    }

    @Test func tomorrowAtHalfPastMidnightStillMeansTheNextDayNotLaterToday() throws {
        let now = ReminderFixture.date(2026, 10, 14, 0, 30)
        let reminder = try #require(ReminderTime.defaultTomorrow.tomorrowSpec.makeReminder(now: now, calendar: calendar, note: nil))
        #expect(reminder.fireDate(calendar: calendar) == ReminderFixture.date(2026, 10, 15, 9, 0))
    }

    @Test func tomorrowAcrossFallBackIsFourteenElapsedHoursNotThirteen() throws {
        let now = ReminderFixture.date(2026, 10, 31, 20, 0)
        let reminder = try #require(ReminderTime.defaultTomorrow.tomorrowSpec.makeReminder(now: now, calendar: calendar, note: nil))
        let due = try #require(reminder.fireDate(calendar: calendar))
        #expect(due == ReminderFixture.date(2026, 11, 1, 9, 0))
        #expect(due.timeIntervalSince(now) == 14 * 3600)
    }

    @Test func tomorrowFollowsTheCalendarItIsResolvedAgainstButAnInstantDoesNot() throws {
        let newYork = ReminderFixture.calendar(in: TimeZone(identifier: "America/New_York")!)
        let wallClock = try #require(ReminderTime.defaultTomorrow.tomorrowSpec
            .makeReminder(now: ReminderFixture.anchor, calendar: calendar, note: nil))
        let instant = try #require(ReminderSpec.after(minutes: 60)
            .makeReminder(now: ReminderFixture.anchor, calendar: calendar, note: nil))
        #expect(wallClock.fireDate(calendar: newYork) == ReminderFixture.date(2026, 10, 15, 9, 0, in: newYork.timeZone))
        #expect(wallClock.fireDate(calendar: newYork) != wallClock.fireDate(calendar: calendar))
        #expect(instant.fireDate(calendar: newYork) == instant.fireDate(calendar: calendar))
    }

    // MARK: - Note

    @Test func noteIsTrimmedEmptyBecomesNilAndLongNotesAreCapped() {
        #expect(SessionReminder.normalizedNote("  call back \n") == "call back")
        #expect(SessionReminder.normalizedNote("   \n ") == nil)
        #expect(SessionReminder.normalizedNote(nil) == nil)
        let long = String(repeating: "x", count: 612)
        #expect(SessionReminder.normalizedNote(long)?.count == 500)
        let reminder = SessionReminder(createdAt: ReminderFixture.anchor, target: .instant(ReminderFixture.anchor), note: "  hi ")
        #expect(reminder.note == "hi")
    }

    // MARK: - Wording

    @Test func phraseNamesTodayTomorrowOrTheDate() {
        let locale = Locale(identifier: "en_US")
        let now = ReminderFixture.anchor
        func clean(_ text: String) -> String { text.replacingOccurrences(of: "\u{202F}", with: " ") }
        #expect(clean(ReminderFormat.phrase(for: ReminderFixture.date(2026, 10, 14, 15, 45), now: now, calendar: calendar, locale: locale)) == "at 3:45 PM")
        #expect(clean(ReminderFormat.phrase(for: ReminderFixture.date(2026, 10, 15, 9, 0), now: now, calendar: calendar, locale: locale)) == "tomorrow at 9:00 AM")
        let later = clean(ReminderFormat.phrase(for: ReminderFixture.date(2026, 10, 22, 9, 0), now: now, calendar: calendar, locale: locale))
        #expect(later.hasPrefix("on "))
        #expect(later.contains("Oct 22"))
        #expect(later.contains("9:00 AM"))
    }

    // MARK: - UI-test clock gating

    @Test func manualReminderClockNeedsBothEnvironmentVariables() {
        let script = UITestDriver.scriptEnvVar
        let clock = UITestDriver.reminderClockEnvVar
        #expect(UITestDriver.reminderClock(environment: [:]) == nil)
        #expect(UITestDriver.reminderClock(environment: [clock: "manual"]) == nil)
        #expect(UITestDriver.reminderClock(environment: [script: "[]"]) == nil)
        #expect(UITestDriver.reminderClock(environment: [script: "[]", clock: "system"]) == nil)
        #expect(UITestDriver.reminderClock(environment: [script: "[]", clock: "manual"]) != nil)
    }

    // MARK: - Feed entry coding

    @Test func feedEntryWithoutAKindDecodesAsABell() throws {
        let json = """
        {"id":"\(UUID().uuidString)","timestamp":1000,"windowID":"\(UUID().uuidString)","sessionID":"\(UUID().uuidString)",
         "paneID":"\(UUID().uuidString)","tabID":"\(UUID().uuidString)","surfaceID":"\(UUID().uuidString)","seen":false}
        """
        let entry = try JSONDecoder().decode(BellFeedEntry.self, from: Data(json.utf8))
        #expect(entry.kind == .bell)
        #expect(entry.reminderDueAt == nil)
    }

    @Test func reminderEntryRoundTripsItsKindAndTimes() throws {
        let entry = BellFeedEntry(
            timestamp: ReminderFixture.anchor,
            windowID: UUID(), sessionID: UUID(), paneID: UUID(), tabID: UUID(), surfaceID: UUID(),
            message: "ship it", kind: .reminder,
            reminderSetAt: ReminderFixture.anchor.addingTimeInterval(-900),
            reminderDueAt: ReminderFixture.anchor.addingTimeInterval(-60))
        let decoded = try JSONDecoder().decode(BellFeedEntry.self, from: JSONEncoder().encode(entry))
        #expect(decoded == entry)
        #expect(decoded.kind == .reminder)
    }

    // MARK: - Feed collapse

    @Test func twoReminderEntriesForTheSameTabAndNoteStaySeparate() {
        let store = BellFeedStore()
        let (window, session, pane, tab) = (UUID(), UUID(), UUID(), UUID())
        func entry(_ at: TimeInterval) -> BellFeedEntry {
            BellFeedEntry(timestamp: Date(timeIntervalSince1970: 2_000 + at), windowID: window, sessionID: session,
                          paneID: pane, tabID: tab, surfaceID: UUID(), message: "stand up", kind: .reminder)
        }
        store.recordOrCollapse(entry(0))
        store.recordOrCollapse(entry(5))
        #expect(store.entries.count == 2)
        #expect(store.entries.allSatisfy { $0.repeatCount == 1 })
    }

    @Test func aReminderIsNeverFoldedIntoAnUnseenBellOfTheSameTabAndText() {
        let store = BellFeedStore()
        let (window, session, pane, tab) = (UUID(), UUID(), UUID(), UUID())
        store.recordOrCollapse(BellFeedEntry(timestamp: Date(timeIntervalSince1970: 2_000), windowID: window, sessionID: session,
                                             paneID: pane, tabID: tab, surfaceID: UUID(), message: "stand up"))
        store.recordOrCollapse(BellFeedEntry(timestamp: Date(timeIntervalSince1970: 2_010), windowID: window, sessionID: session,
                                             paneID: pane, tabID: tab, surfaceID: UUID(), message: "stand up", kind: .reminder))
        #expect(store.entries.count == 2)
        #expect(Set(store.entries.map(\.kind)) == [.bell, .reminder])
    }

    // MARK: - Display text

    @Test func displayTextIsTheNoteOrComeBackToTheSession() {
        let withNote = SessionReminder(createdAt: ReminderFixture.anchor, target: .instant(ReminderFixture.anchor), note: "review PR 42")
        #expect(withNote.displayText(sessionTitle: "api-server") == "review PR 42")
        let without = SessionReminder(createdAt: ReminderFixture.anchor, target: .instant(ReminderFixture.anchor))
        #expect(without.displayText(sessionTitle: "api-server") == "Come back to api-server")
        #expect(SessionReminder.displayText(note: "  ", sessionTitle: "api-server") == "Come back to api-server")
    }

    // MARK: - At

    @Test func anAtSpecResolvesToThatInstant() throws {
        let date = ReminderFixture.anchor.addingTimeInterval(90 * 60)
        let reminder = try #require(ReminderSpec.at(date).makeReminder(now: ReminderFixture.anchor, calendar: calendar, note: "x"))
        #expect(reminder.target == .instant(date))
        #expect(reminder.note == "x")
        #expect(ReminderSpec.at(ReminderFixture.anchor.addingTimeInterval(60))
            .makeReminder(now: ReminderFixture.anchor, calendar: calendar, note: nil) != nil)
        #expect(ReminderSpec.at(ReminderFixture.anchor.addingTimeInterval(7 * 86_400))
            .makeReminder(now: ReminderFixture.anchor, calendar: calendar, note: nil) != nil)
    }

    @Test func anAtSpecUnderAMinuteOrBeyondSevenDaysIsRejected() {
        for offset: TimeInterval in [-60, 0, 59, 7 * 86_400 + 1] {
            #expect(ReminderSpec.at(ReminderFixture.anchor.addingTimeInterval(offset))
                .makeReminder(now: ReminderFixture.anchor, calendar: calendar, note: nil) == nil)
        }
    }

    @Test func todayAtResolvesInTheCalendarsZone() {
        #expect(ReminderSpec.todayAt(hour: 17, minute: 30, now: ReminderFixture.anchor, calendar: calendar)
            == ReminderFixture.date(2026, 10, 14, 17, 30))
        #expect(ReminderSpec.todayAt(hour: 24, minute: 0, now: ReminderFixture.anchor, calendar: calendar) == nil)
    }

    // MARK: - Relative lines

    private let locale = Locale(identifier: "en_US")

    private func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{202F}", with: " ")
    }

    @Test func relativeLineSaysInMinutesUpToAnHourThenAClockPhrase() {
        let now = ReminderFixture.anchor
        func line(_ seconds: TimeInterval) -> String {
            plain(ReminderFormat.relativeLine(due: now.addingTimeInterval(seconds), now: now, calendar: calendar, locale: locale))
        }
        #expect(line(10) == "in 1 min")
        #expect(line(17 * 60 + 5) == "in 18 min")
        #expect(line(60 * 60) == "in 60 min")
        #expect(line(2 * 3600) == "at 5:00 PM")
        #expect(line(18 * 3600) == "tomorrow at 9:00 AM")
    }

    @Test func dueLineSaysJustNowThenMinutesAgoThenTheTime() {
        let due = ReminderFixture.anchor
        func line(_ seconds: TimeInterval) -> String {
            plain(ReminderFormat.dueLine(dueAt: due, now: due.addingTimeInterval(seconds), calendar: calendar, locale: locale))
        }
        #expect(line(20) == "due just now")
        #expect(line(2 * 60 + 10) == "due 2 min ago")
        #expect(line(59 * 60) == "due 59 min ago")
        #expect(line(2 * 3600) == "due at 3:00 PM")
    }

    // MARK: - Quit confirmation

    @Test func quitConfirmationTextDescribesScheduledReminders() {
        let none = QuitConfirmation.informativeText(openTabs: 3, pendingReminders: 0, remindersStillNotify: true)
        let some = QuitConfirmation.informativeText(openTabs: 3, pendingReminders: 2, remindersStillNotify: true)
        #expect(!none.contains("reminder"))
        #expect(some.hasPrefix(none))
        #expect(some.contains("2 pending reminder(s) will still notify you, but their Sessions will close."))
    }

    @Test func quitConfirmationTextSaysCancelledWhenNotificationsAreOff() {
        let none = QuitConfirmation.informativeText(openTabs: 3, pendingReminders: 0, remindersStillNotify: false)
        let some = QuitConfirmation.informativeText(openTabs: 3, pendingReminders: 2, remindersStillNotify: false)
        #expect(!none.contains("reminder"))
        #expect(some.hasPrefix(none))
        #expect(some.contains("2 pending reminder(s) will be cancelled."))
    }
}
