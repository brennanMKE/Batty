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

    private func fired(note: String?) -> FiredReminder {
        let setAt = ReminderFixture.anchor
        let due = setAt.addingTimeInterval(15 * 60)
        return FiredReminder(
            id: UUID(), sessionID: UUID(), windowID: UUID(), note: note,
            createdAt: setAt, dueAt: due, firedAt: due.addingTimeInterval(5))
    }

    @Test func reminderUserInfoCarriesNoBellEntryID() {
        let fired = fired(note: "ship it")
        let projectID = UUID()
        let info = BellNotifier.reminderUserInfo(fired: fired, projectID: projectID)
        #expect(info[BellNotifier.entryIdUserInfoKey] == nil)
        let payload = NotificationTapPayload(userInfo: info, actionIdentifier: nil)
        #expect(payload.entryID == nil)
        #expect(payload == NotificationTapPayload(
            entryID: nil, reminderID: fired.id, projectID: projectID, sessionID: fired.sessionID, note: "ship it", action: .default))
    }

    @Test func reminderContentKeepsTitleSubtitleAndBody() {
        let content = BellNotifier.reminderContent(fired: fired(note: "deploy"), projectID: nil, sessionTitle: "api")
        #expect(content.title == "deploy")
        #expect(content.subtitle == "api")
        #expect(content.body.hasPrefix("Set at "))
        #expect(content.categoryIdentifier == ReminderNotification.inAppCategory)
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
}
