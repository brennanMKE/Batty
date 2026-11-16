// RemindersListModel.swift

import Foundation

/// One row of the Reminders popover.
nonisolated enum RemindersRowID: Hashable, Sendable {
    /// A fired Reminder, by its `FiredReminder.id`.
    case due(UUID)
    /// A pending Reminder, by its Session's id (one per Session).
    case upcoming(UUID)
}

nonisolated struct RemindersSessionInput: Equatable, Sendable {
    var id: UUID
    var title: String
    var reminder: SessionReminder?
}

nonisolated struct RemindersDueRow: Equatable, Sendable {
    var fired: FiredReminder
    var sessionTitle: String
    /// False when the Session already has a newer pending Reminder.
    var canRemindAgain: Bool

    var id: RemindersRowID { .due(fired.id) }
    var sessionID: UUID { fired.sessionID }
    var text: String { fired.displayText(sessionTitle: sessionTitle) }
    var isUnread: Bool { !fired.seen }
}

nonisolated struct RemindersUpcomingRow: Equatable, Sendable {
    var sessionID: UUID
    var sessionTitle: String
    var reminder: SessionReminder
    /// Nil when a wall-clock target can't be resolved.
    var dueAt: Date?

    var id: RemindersRowID { .upcoming(sessionID) }
    var text: String { reminder.displayText(sessionTitle: sessionTitle) }
}

nonisolated enum RemindersToolbarGlyph: Equatable, Sendable {
    case idle, filled, ringing

    var systemImage: String {
        switch self {
        case .idle: "alarm"
        case .filled: "alarm.fill"
        case .ringing: "alarm.waves.left.and.right.fill"
        }
    }

    var usesAccent: Bool { self == .ringing }
}

/// What the Reminders toolbar button and popover show: fired Reminders
/// (Due, newest first) then pending ones (Upcoming, soonest first).
nonisolated struct RemindersListModel: Equatable, Sendable {
    let due: [RemindersDueRow]
    let upcoming: [RemindersUpcomingRow]

    /// `sessions` is every Session of every Window, in Window then Sidebar order.
    init(fired: [FiredReminder], sessions: [RemindersSessionInput], calendar: Calendar) {
        let byID = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        due = fired.enumerated()
            .sorted { lhs, rhs in
                lhs.element.firedAt != rhs.element.firedAt
                    ? lhs.element.firedAt > rhs.element.firedAt
                    : lhs.offset < rhs.offset
            }
            .map { _, item in
                let session = byID[item.sessionID]
                let pendingID = session?.reminder?.id
                return RemindersDueRow(
                    fired: item,
                    sessionTitle: session?.title ?? String(localized: "(closed)"),
                    canRemindAgain: pendingID == nil || pendingID == item.id)
            }
        upcoming = sessions.enumerated()
            .compactMap { offset, session -> (Int, RemindersUpcomingRow)? in
                guard let reminder = session.reminder else { return nil }
                return (offset, RemindersUpcomingRow(
                    sessionID: session.id, sessionTitle: session.title,
                    reminder: reminder, dueAt: reminder.fireDate(calendar: calendar)))
            }
            .sorted { lhs, rhs in
                switch (lhs.1.dueAt, rhs.1.dueAt) {
                case let (l?, r?) where l != r: l < r
                case (_?, nil): true
                case (nil, _?): false
                default: lhs.0 < rhs.0
                }
            }
            .map(\.1)
    }

    var rowIDs: [RemindersRowID] { due.map(\.id) + upcoming.map(\.id) }
    var isEmpty: Bool { due.isEmpty && upcoming.isEmpty }
    var unreadCount: Int { due.count { $0.isUnread } }
    var readCount: Int { due.count - unreadCount }
    var upcomingCount: Int { upcoming.count }

    var glyph: RemindersToolbarGlyph {
        if unreadCount > 0 { return .ringing }
        if upcomingCount > 0 || readCount > 0 { return .filled }
        return .idle
    }

    /// Contains "unread" exactly when an unread fired Reminder exists.
    var accessibilityValue: String {
        var parts: [String] = []
        if !due.isEmpty {
            let unread = unreadCount
            if unread == 0 {
                parts.append("\(due.count) due")
            } else if unread == due.count {
                parts.append("\(due.count) unread due")
            } else {
                parts.append("\(due.count) due, \(unread) unread")
            }
        }
        if !upcoming.isEmpty { parts.append("\(upcoming.count) upcoming") }
        return parts.isEmpty ? "none" : parts.joined(separator: ", ")
    }

    var initialSelection: RemindersRowID? {
        due.first(where: \.isUnread)?.id ?? due.first?.id ?? upcoming.first?.id
    }

    /// Up and Down across Due then Upcoming, wrapping at either end.
    func moved(from current: RemindersRowID?, by delta: Int) -> RemindersRowID? {
        let ids = rowIDs
        guard !ids.isEmpty else { return nil }
        guard let current, let index = ids.firstIndex(of: current) else {
            return delta > 0 ? ids.first : ids.last
        }
        return ids[((index + delta) % ids.count + ids.count) % ids.count]
    }

    /// What `key` does with `selection` selected; nil when it does nothing.
    func action(for key: RemindersListKey, selection: RemindersRowID?) -> RemindersKeyAction? {
        switch key {
        case .up: return moved(from: selection, by: -1).map(RemindersKeyAction.select)
        case .down: return moved(from: selection, by: 1).map(RemindersKeyAction.select)
        default: break
        }
        let due = selection.flatMap { id in self.due.first { $0.id == id } }
        let upcoming = selection.flatMap { id in self.upcoming.first { $0.id == id } }
        switch key {
        case .open:
            return (due?.sessionID ?? upcoming?.sessionID).map(RemindersKeyAction.open)
        case .delete:
            if let due { return .done(due) }
            return upcoming.map(RemindersKeyAction.cancel)
        case .edit:
            return upcoming.map(RemindersKeyAction.edit)
        case .remindAgain:
            guard let due, due.canRemindAgain else { return nil }
            return .remindAgain(due)
        case .up, .down:
            return nil
        }
    }

    /// Keeps `current` when it survived; otherwise the row now at its old
    /// index, clamped to the last row.
    static func selection(
        _ current: RemindersRowID?,
        after previous: [RemindersRowID],
        in next: RemindersListModel
    ) -> RemindersRowID? {
        let ids = next.rowIDs
        guard let current else { return nil }
        if ids.contains(current) { return current }
        guard !ids.isEmpty, let old = previous.firstIndex(of: current) else { return ids.first }
        return ids[min(old, ids.count - 1)]
    }

    /// Reads the store; writes nothing.
    @MainActor static func current(in store: AppStateStore) -> RemindersListModel {
        RemindersListModel(
            fired: store.firedReminders.items,
            sessions: store.windows.flatMap(\.sessions).map {
                RemindersSessionInput(id: $0.id, title: $0.title, reminder: $0.reminder)
            },
            calendar: store.reminderScheduler.calendar)
    }
}

/// The Reminders popover's keys: Up, Down, Return, Delete, `E` and `R`.
nonisolated enum RemindersListKey: CaseIterable, Sendable {
    case up, down, open, delete, edit, remindAgain
}

nonisolated enum RemindersKeyAction: Equatable, Sendable {
    case select(RemindersRowID)
    case open(UUID)
    case done(RemindersDueRow)
    case cancel(RemindersUpcomingRow)
    case edit(RemindersUpcomingRow)
    /// Again in 15 minutes.
    case remindAgain(RemindersDueRow)
}

/// A Window acts on `.battyToggleReminders` when it is key, or when its own
/// popover is showing: the popover's window is then key, and
/// `keyWindowRuntime()` can't see past it.
nonisolated enum RemindersPopoverToggle {
    static func shouldHandle(isKeyWindow: Bool, isShown: Bool) -> Bool { isKeyWindow || isShown }
}
