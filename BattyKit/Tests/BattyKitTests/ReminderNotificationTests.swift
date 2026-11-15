// ReminderNotificationTests.swift

import Foundation
import Testing
import UserNotifications
@testable import BattyKit

@MainActor
struct ReminderNotificationTests {
    private func category(_ id: String) throws -> UNNotificationCategory {
        try #require(ReminderNotification.categories().first { $0.identifier == id })
    }

    @Test func inAppCategoryOffersOpenAndBothRemindAgainActions() throws {
        let actions = try category(ReminderNotification.inAppCategory).actions
        #expect(actions.map(\.identifier) == [
            "co.sstools.Batty.reminder.open",
            "co.sstools.Batty.reminder.remindAgain.15",
            "co.sstools.Batty.reminder.remindAgain.60",
        ])
        #expect(actions.map(\.title) == ["Open Session", "Remind Again in 15 Minutes", "Remind Again in 1 Hour"])
        #expect(actions[0].options.contains(.foreground))
        #expect(!actions[1].options.contains(.foreground))
        #expect(!actions[2].options.contains(.foreground))
    }

    @Test func scheduledCategoryOffersOnlyOpen() throws {
        let actions = try category(ReminderNotification.scheduledCategory).actions
        #expect(actions.map(\.identifier) == [ReminderNotification.openAction])
    }

    @Test func onTimeDeliveryBodySaysSetAt() {
        let calendar = ReminderFixture.calendar()
        let setAt = ReminderFixture.anchor
        let due = setAt.addingTimeInterval(15 * 60)
        let content = ReminderNotification.content(
            note: "deploy", sessionTitle: "api", setAt: setAt, dueAt: due, deliveredAt: due.addingTimeInterval(30),
            calendar: calendar, locale: Locale(identifier: "en_US"))
        #expect(content.title == "deploy")
        #expect(content.subtitle == "api")
        #expect(content.body.replacingOccurrences(of: "\u{202F}", with: " ") == "Set at 3:00 PM")
    }

    @Test func lateDeliveryBodySaysDueAt() {
        let calendar = ReminderFixture.calendar()
        let setAt = ReminderFixture.anchor
        let due = setAt.addingTimeInterval(15 * 60)
        let content = ReminderNotification.content(
            note: nil, sessionTitle: "api", setAt: setAt, dueAt: due, deliveredAt: due.addingTimeInterval(61),
            calendar: calendar, locale: Locale(identifier: "en_US"))
        #expect(content.title == "Come back to api")
        #expect(content.body.replacingOccurrences(of: "\u{202F}", with: " ") == "Due at 3:15 PM")
    }
}

@MainActor
struct NotificationTapPayloadTests {
    @Test func remindAgainActionIdentifiersParseToMinutes() {
        #expect(NotificationTapPayload(userInfo: [:], actionIdentifier: "co.sstools.Batty.reminder.remindAgain.15").action
            == .remindAgain(minutes: 15))
        #expect(NotificationTapPayload(userInfo: [:], actionIdentifier: "co.sstools.Batty.reminder.remindAgain.60").action
            == .remindAgain(minutes: 60))
        #expect(NotificationTapPayload(userInfo: [:], actionIdentifier: "co.sstools.Batty.reminder.remindAgain.7").action
            == .default)
    }

    @Test func defaultAndOpenActionsParseToOpen() {
        #expect(NotificationTapPayload(userInfo: [:], actionIdentifier: UNNotificationDefaultActionIdentifier).action == .default)
        #expect(NotificationTapPayload(userInfo: [:], actionIdentifier: ReminderNotification.openAction).action == .open)
        #expect(NotificationTapPayload(userInfo: [:]).action == .default)
    }

    @Test func userInfoCarriesSessionAndNote() {
        let entryID = UUID()
        let sessionID = UUID()
        let entry = BellFeedEntry(
            id: entryID,
            timestamp: ReminderFixture.anchor,
            windowID: UUID(),
            sessionID: sessionID,
            paneID: UUID(),
            tabID: UUID(),
            surfaceID: UUID(),
            message: "ship it",
            seen: false,
            kind: .reminder)
        let reminderID = UUID()
        let info = BellNotifier.reminderUserInfo(entry: entry, reminderID: reminderID, projectID: nil)
        let payload = NotificationTapPayload(userInfo: info, actionIdentifier: nil)
        #expect(payload == NotificationTapPayload(
            entryID: entryID, reminderID: reminderID, projectID: nil, sessionID: sessionID, note: "ship it", action: .default))
    }
}
