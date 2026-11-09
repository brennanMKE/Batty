// ScheduledReminderNotification.swift

import Foundation

/// The system notification request a pending Reminder is scheduled as, so it
/// still notifies after Batty quits. The in-app post uses the same
/// identifier, so posting replaces the scheduled request.
nonisolated public struct ScheduledReminderNotification: Sendable, Equatable {
    public static let identifierPrefix = "co.sstools.Batty.reminder."
    public static let reminderIDUserInfoKey = "co.sstools.Batty.reminderID"
    public static let projectIDUserInfoKey = "co.sstools.Batty.projectID"

    public let reminderID: UUID
    public let title: String
    public let body: String
    public let projectID: UUID?
    public let playSound: Bool
    /// Trigger components. An instant Reminder is pinned to UTC so a time
    /// zone change does not move it; a Tomorrow Reminder carries no time
    /// zone, so it floats with the local zone like the in-app scheduler.
    public let dateComponents: DateComponents

    public var identifier: String { Self.identifier(for: reminderID) }

    public static func identifier(for reminderID: UUID) -> String {
        identifierPrefix + reminderID.uuidString
    }

    public static func make(
        reminder: SessionReminder,
        sessionTitle: String,
        projectID: UUID?,
        playSound: Bool
    ) -> ScheduledReminderNotification {
        let text = BellNotifier.reminderText(note: reminder.note, sessionTitle: sessionTitle)
        let components: DateComponents
        switch reminder.target {
        case .instant(let date):
            var utc = Calendar(identifier: .gregorian)
            let zone = TimeZone(identifier: "UTC")!
            utc.timeZone = zone
            // Rounded up: the trigger has whole-second resolution, and firing
            // after the in-app scheduler's exact `date` lets it win the race.
            let rounded = Date(timeIntervalSinceReferenceDate: date.timeIntervalSinceReferenceDate.rounded(.up))
            var c = utc.dateComponents([.year, .month, .day, .hour, .minute, .second], from: rounded)
            c.timeZone = zone
            components = c
        case .wallClock(let c):
            components = c
        }
        return ScheduledReminderNotification(
            reminderID: reminder.id,
            title: text.title,
            body: text.body,
            projectID: projectID,
            playSound: playSound,
            dateComponents: components
        )
    }

    public var userInfo: [String: String] {
        var info = [Self.reminderIDUserInfoKey: reminderID.uuidString]
        if let projectID {
            info[Self.projectIDUserInfoKey] = projectID.uuidString
        }
        return info
    }

    /// Whether `willPresent` shows a delivered notification. A scheduled
    /// Reminder (Reminder id, no entry id) is suppressed while its Reminder
    /// is still live or already fired in-app this launch, because the in-app
    /// fire shows the one banner, and whenever system notifications are off.
    /// An orphan from an earlier launch, and every in-app post, is shown.
    public static func shouldPresent(
        payload: NotificationTapPayload,
        isLiveReminder: Bool,
        alreadyFiredInApp: Bool,
        systemNotificationsEnabled: Bool
    ) -> Bool {
        guard payload.reminderID != nil, payload.entryID == nil else { return true }
        return !isLiveReminder && !alreadyFiredInApp && systemNotificationsEnabled
    }
}

nonisolated public struct NotificationTapPayload: Sendable, Equatable {
    public var entryID: UUID?
    public var reminderID: UUID?
    public var projectID: UUID?

    public init(entryID: UUID? = nil, reminderID: UUID? = nil, projectID: UUID? = nil) {
        self.entryID = entryID
        self.reminderID = reminderID
        self.projectID = projectID
    }

    public init(userInfo: [AnyHashable: Any]) {
        func uuid(_ key: String) -> UUID? {
            (userInfo[key] as? String).flatMap(UUID.init(uuidString:))
        }
        self.init(
            entryID: uuid(BellNotifier.entryIdUserInfoKey),
            reminderID: uuid(ScheduledReminderNotification.reminderIDUserInfoKey),
            projectID: uuid(ScheduledReminderNotification.projectIDUserInfoKey)
        )
    }
}

nonisolated public enum NotificationTapRoute: Equatable, Sendable {
    case jumpToEntry(UUID)
    case openProject(UUID)
    case activateOnly
}
