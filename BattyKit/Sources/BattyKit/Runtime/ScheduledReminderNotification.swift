// ScheduledReminderNotification.swift

import Foundation
import UserNotifications

/// The system notification request a pending Reminder is scheduled as, so it
/// still notifies after Batty quits. The in-app post uses the same
/// identifier, so posting replaces the scheduled request.
nonisolated public struct ScheduledReminderNotification: Sendable, Equatable {
    public static let identifierPrefix = "co.sstools.Batty.reminder."
    public static let reminderIDUserInfoKey = "co.sstools.Batty.reminderID"
    public static let projectIDUserInfoKey = "co.sstools.Batty.projectID"
    public static let sessionIDUserInfoKey = "co.sstools.Batty.sessionID"
    public static let noteUserInfoKey = "co.sstools.Batty.reminderNote"

    public let reminderID: UUID
    public let title: String
    public let subtitle: String
    public let body: String
    public let categoryIdentifier: String
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
        let due = reminder.fireDate(calendar: .current) ?? reminder.createdAt
        let text = ReminderNotification.content(
            note: reminder.note, sessionTitle: sessionTitle,
            setAt: reminder.createdAt, dueAt: due, deliveredAt: due)
        return ScheduledReminderNotification(
            reminderID: reminder.id,
            title: text.title,
            subtitle: text.subtitle,
            body: text.body,
            categoryIdentifier: ReminderNotification.scheduledCategory,
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

/// What the user did with a delivered notification.
nonisolated public enum NotificationAction: Sendable, Equatable {
    /// A click on the banner itself.
    case `default`
    /// The Open Session action button.
    case open
    case remindAgain(minutes: Int)
}

/// A Reminder notification's text, categories and action buttons. The
/// in-app post offers Remind Again; the request scheduled with macOS, which
/// may arrive after Batty quit, offers only Open Session.
nonisolated public enum ReminderNotification {
    public static let inAppCategory = "co.sstools.Batty.reminder.inApp"
    public static let scheduledCategory = "co.sstools.Batty.reminder.scheduled"
    public static let openAction = "co.sstools.Batty.reminder.open"
    public static let remindAgainActionPrefix = "co.sstools.Batty.reminder.remindAgain."
    public static let remindAgainMinutes = [15, 60]

    public static func remindAgainAction(minutes: Int) -> String {
        remindAgainActionPrefix + "\(minutes)"
    }

    public static func categories() -> Set<UNNotificationCategory> {
        let open = UNNotificationAction(
            identifier: openAction, title: String(localized: "Open Session"), options: [.foreground])
        let again = remindAgainMinutes.map { minutes in
            UNNotificationAction(
                identifier: remindAgainAction(minutes: minutes),
                title: minutes == 60
                    ? String(localized: "Remind Again in 1 Hour")
                    : String(localized: "Remind Again in \(minutes) Minutes"),
                options: [])
        }
        return [
            UNNotificationCategory(identifier: inAppCategory, actions: [open] + again, intentIdentifiers: []),
            UNNotificationCategory(identifier: scheduledCategory, actions: [open], intentIdentifiers: []),
        ]
    }

    /// Title = the Reminder's text, subtitle = the Session, body = when it
    /// was set, or when it was due if it is delivered late.
    public static func content(
        note: String?,
        sessionTitle: String,
        setAt: Date,
        dueAt: Date,
        deliveredAt: Date,
        calendar: Calendar = .current,
        locale: Locale = .autoupdatingCurrent
    ) -> (title: String, subtitle: String, body: String) {
        (
            SessionReminder.displayText(note: note, sessionTitle: sessionTitle),
            sessionTitle,
            ReminderFormat.notificationBody(
                setAt: setAt, dueAt: dueAt, deliveredAt: deliveredAt, calendar: calendar, locale: locale)
        )
    }
}

nonisolated public struct NotificationTapPayload: Sendable, Equatable {
    public var entryID: UUID?
    public var reminderID: UUID?
    public var projectID: UUID?
    public var sessionID: UUID?
    public var note: String?
    public var action: NotificationAction

    public init(
        entryID: UUID? = nil,
        reminderID: UUID? = nil,
        projectID: UUID? = nil,
        sessionID: UUID? = nil,
        note: String? = nil,
        action: NotificationAction = .default
    ) {
        self.entryID = entryID
        self.reminderID = reminderID
        self.projectID = projectID
        self.sessionID = sessionID
        self.note = note
        self.action = action
    }

    /// A delivery with no response yet (`willPresent`): `.default`.
    public init(userInfo: [AnyHashable: Any]) {
        self.init(userInfo: userInfo, actionIdentifier: nil)
    }

    public init(userInfo: [AnyHashable: Any], actionIdentifier: String?) {
        func uuid(_ key: String) -> UUID? {
            (userInfo[key] as? String).flatMap(UUID.init(uuidString:))
        }
        self.init(
            entryID: uuid(BellNotifier.entryIdUserInfoKey),
            reminderID: uuid(ScheduledReminderNotification.reminderIDUserInfoKey),
            projectID: uuid(ScheduledReminderNotification.projectIDUserInfoKey),
            sessionID: uuid(ScheduledReminderNotification.sessionIDUserInfoKey),
            note: userInfo[ScheduledReminderNotification.noteUserInfoKey] as? String,
            action: Self.action(for: actionIdentifier)
        )
    }

    static func action(for identifier: String?) -> NotificationAction {
        guard let identifier else { return .default }
        if identifier == ReminderNotification.openAction { return .open }
        if identifier.hasPrefix(ReminderNotification.remindAgainActionPrefix),
           let minutes = Int(identifier.dropFirst(ReminderNotification.remindAgainActionPrefix.count)),
           ReminderNotification.remindAgainMinutes.contains(minutes) {
            return .remindAgain(minutes: minutes)
        }
        return .default
    }
}

nonisolated public enum NotificationTapRoute: Equatable, Sendable {
    case jumpToEntry(UUID)
    case openProject(UUID)
    case activateOnly
}
