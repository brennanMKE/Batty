// ScheduledReminderNotificationTests.swift

import Foundation
import Testing
@testable import BattyKit

@MainActor
struct ScheduledReminderNotificationTests {
    private let utc = TimeZone(identifier: "UTC")!

    @Test func instantReminderUsesUTCComponentsThatResolveToItsFireDate() throws {
        let due = ReminderFixture.anchor.addingTimeInterval(15 * 60 + 7)
        let reminder = SessionReminder(createdAt: ReminderFixture.anchor, target: .instant(due))
        let scheduled = ScheduledReminderNotification.make(reminder: reminder, sessionTitle: "s", projectID: nil, playSound: true)
        #expect(scheduled.dateComponents.timeZone == utc)
        #expect(scheduled.dateComponents.second == 7)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        #expect(calendar.date(from: scheduled.dateComponents) == due)
    }

    @Test func instantReminderWithAFractionalSecondRoundsTheTriggerUp() throws {
        let due = ReminderFixture.anchor.addingTimeInterval(15 * 60 + 7.25)
        let reminder = SessionReminder(createdAt: ReminderFixture.anchor, target: .instant(due))
        let scheduled = ScheduledReminderNotification.make(reminder: reminder, sessionTitle: "s", projectID: nil, playSound: true)
        #expect(scheduled.dateComponents.second == 8)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        #expect(calendar.date(from: scheduled.dateComponents) == ReminderFixture.anchor.addingTimeInterval(15 * 60 + 8))
    }

    @Test func tomorrowReminderUsesACalendarTriggerWithItsWallClockComponents() throws {
        let calendar = ReminderFixture.calendar()
        let now = ReminderFixture.date(2026, 10, 31, 20, 0)
        let reminder = try #require(ReminderSpec.tomorrow(hour: 9, minute: 0).makeReminder(now: now, calendar: calendar, note: nil))
        let scheduled = ScheduledReminderNotification.make(reminder: reminder, sessionTitle: "s", projectID: nil, playSound: false)
        let c = scheduled.dateComponents
        #expect([c.year, c.month, c.day, c.hour, c.minute] == [2026, 11, 1, 9, 0])
        #expect(c.timeZone == nil)
        let fire = try #require(calendar.date(from: c))
        #expect(fire.timeIntervalSince(now) == 14 * 3600)
        #expect(scheduled.playSound == false)
    }

    @Test func identifierIsDerivedFromTheReminderID() {
        let id = UUID()
        let reminder = SessionReminder(id: id, createdAt: ReminderFixture.anchor, target: .instant(ReminderFixture.anchor))
        let scheduled = ScheduledReminderNotification.make(reminder: reminder, sessionTitle: "s", projectID: nil, playSound: true)
        #expect(scheduled.identifier == "co.sstools.Batty.reminder." + id.uuidString)
        #expect(scheduled.identifier == ScheduledReminderNotification.identifier(for: id))
    }

    @Test func scheduledUserInfoCarriesProjectIDForAProjectBackedSession() {
        let projectID = UUID()
        let reminder = SessionReminder(createdAt: ReminderFixture.anchor, target: .instant(ReminderFixture.anchor))
        let info = ScheduledReminderNotification.make(reminder: reminder, sessionTitle: "s", projectID: projectID, playSound: true).userInfo
        #expect(info[ScheduledReminderNotification.reminderIDUserInfoKey] == reminder.id.uuidString)
        #expect(info[ScheduledReminderNotification.projectIDUserInfoKey] == projectID.uuidString)
    }

    @Test func scheduledUserInfoOmitsProjectIDForAPlainSession() {
        let reminder = SessionReminder(createdAt: ReminderFixture.anchor, target: .instant(ReminderFixture.anchor))
        let info = ScheduledReminderNotification.make(reminder: reminder, sessionTitle: "s", projectID: nil, playSound: true).userInfo
        #expect(info[ScheduledReminderNotification.projectIDUserInfoKey] == nil)
        #expect(info.count == 1)
    }

    @Test func tapPayloadRoundTripsThroughUserInfo() {
        let reminder = SessionReminder(createdAt: ReminderFixture.anchor, target: .instant(ReminderFixture.anchor))
        let projectID = UUID()
        let info = ScheduledReminderNotification.make(reminder: reminder, sessionTitle: "s", projectID: projectID, playSound: true).userInfo
        let payload = NotificationTapPayload(userInfo: info)
        #expect(payload == NotificationTapPayload(entryID: nil, reminderID: reminder.id, projectID: projectID))
    }

    @Test func tapPayloadIgnoresMalformedValues() {
        let payload = NotificationTapPayload(userInfo: [
            BellNotifier.entryIdUserInfoKey: "not-a-uuid",
            ScheduledReminderNotification.reminderIDUserInfoKey: 42,
        ])
        #expect(payload == NotificationTapPayload())
    }

    @Test func willPresentSuppressesAScheduledReminderWhileRunning() {
        let payload = NotificationTapPayload(reminderID: UUID())
        #expect(!ScheduledReminderNotification.shouldPresent(payload: payload, isLiveReminder: true, alreadyFiredInApp: false, systemNotificationsEnabled: true))
    }

    @Test func willPresentShowsAnOrphanedScheduledReminder() {
        let payload = NotificationTapPayload(reminderID: UUID())
        #expect(ScheduledReminderNotification.shouldPresent(payload: payload, isLiveReminder: false, alreadyFiredInApp: false, systemNotificationsEnabled: true))
    }

    @Test func willPresentSuppressesAScheduledReminderAlreadyFiredInApp() {
        let payload = NotificationTapPayload(reminderID: UUID())
        #expect(!ScheduledReminderNotification.shouldPresent(payload: payload, isLiveReminder: false, alreadyFiredInApp: true, systemNotificationsEnabled: true))
    }

    @Test func willPresentSuppressesScheduledRemindersWhenNotificationsAreOff() {
        let payload = NotificationTapPayload(reminderID: UUID())
        #expect(!ScheduledReminderNotification.shouldPresent(payload: payload, isLiveReminder: false, alreadyFiredInApp: false, systemNotificationsEnabled: false))
    }

    @Test func willPresentAlwaysShowsAnInAppPost() {
        let payload = NotificationTapPayload(entryID: UUID(), reminderID: UUID())
        #expect(ScheduledReminderNotification.shouldPresent(payload: payload, isLiveReminder: true, alreadyFiredInApp: false, systemNotificationsEnabled: false))
    }
}
