// AppStateStore+Reminders.swift

import Foundation
import os

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "AppStateStoreReminders")

extension AppStateStore {
    /// The default for every Tomorrow request that names no time.
    public var tomorrowReminderSpec: ReminderSpec { tomorrowReminderTime.tomorrowSpec }

    func rememberTomorrowReminderTime(_ time: ReminderTime) {
        guard time != tomorrowReminderTime else { return }
        tomorrowReminderTime = time
        SettingsPreference.storeReminderTomorrowTime(time, defaults: preferences)
    }

    /// The Reminder sheet's Set: `editReminder`, and a Tomorrow choice
    /// becomes the remembered Tomorrow time. Presets and the one-click
    /// Tomorrow item go through `setReminder` and never change it.
    @discardableResult
    public func commitReminderSheet(_ spec: ReminderSpec, note: String?, forSessionID sessionID: UUID) -> SessionReminder? {
        let result = editReminder(spec, note: note, forSessionID: sessionID)
        if result != nil, case .tomorrow(let hour, let minute) = spec {
            rememberTomorrowReminderTime(ReminderTime(hour: hour, minute: minute))
        }
        return result
    }

    /// Sets the Session's Reminder, replacing any it already has: one per
    /// Session, and the edit path. Records no feed entry and posts nothing.
    /// Returns nil when the Session is gone or `spec` is out of bounds.
    @discardableResult
    public func setReminder(_ spec: ReminderSpec, note: String? = nil, forSessionID sessionID: UUID) -> SessionReminder? {
        guard let session = session(id: sessionID) else {
            logger.notice("setReminder: session \(sessionID, privacy: .public) not found")
            return nil
        }
        guard let reminder = spec.makeReminder(
            now: reminderScheduler.now,
            calendar: reminderScheduler.calendar,
            note: note
        ) else {
            logger.notice("setReminder: spec out of bounds for session \(sessionID, privacy: .public)")
            return nil
        }
        session.reminder = reminder
        reminderScheduler.set(reminder, forSessionID: sessionID)
        return reminder
    }

    /// The sheet's Update path. A Tomorrow Reminder edited without changing
    /// its time keeps the date it already resolved to, so editing only the
    /// note after midnight does not push it a day later; any other change
    /// is a fresh `setReminder`.
    @discardableResult
    public func editReminder(_ spec: ReminderSpec, note: String?, forSessionID sessionID: UUID) -> SessionReminder? {
        guard let session = session(id: sessionID),
              var existing = session.reminder,
              case .wallClock(let components) = existing.target,
              case .tomorrow(let hour, let minute) = spec,
              components.hour == hour, components.minute == minute
        else { return setReminder(spec, note: note, forSessionID: sessionID) }
        existing.note = SessionReminder.normalizedNote(note)
        session.reminder = existing
        reminderScheduler.set(existing, forSessionID: sessionID)
        return existing
    }

    /// Removes the Session's pending Reminder at once, with no confirmation.
    public func cancelReminder(forSessionID sessionID: UUID) {
        session(id: sessionID)?.reminder = nil
        reminderScheduler.cancel(sessionID: sessionID)
    }

    /// Pending Reminders across every window, for the quit confirmation.
    public var pendingReminderCount: Int {
        windows.reduce(0) { acc, window in
            acc + window.sessions.filter { $0.reminder != nil }.count
        }
    }

    /// The scheduler's `onFire`. Resolves the owning Window and Session now,
    /// not when the Reminder was set. The entry is recorded unseen even when
    /// the Session is selected and Batty is frontmost, with `record(_:)`
    /// rather than `recordOrCollapse` so two Reminders never merge, and it
    /// bumps no unseen-bell counter. The notification is posted whatever the
    /// Session's mute setting, but not when the app-wide "Show system
    /// notifications" setting is off.
    func fireReminder(_ firing: ReminderFiring) {
        guard let window = windowOwning(sessionID: firing.sessionID),
              let session = window.sessions.first(where: { $0.id == firing.sessionID })
        else {
            logger.notice("fireReminder: session \(firing.sessionID, privacy: .public) is gone; dropping")
            return
        }
        if session.reminder?.id == firing.reminder.id {
            session.reminder = nil
        }
        let pane = session.focusedPaneAnyKind
        let entry = BellFeedEntry(
            timestamp: reminderScheduler.now,
            windowID: window.id.value,
            sessionID: session.id,
            paneID: pane.id,
            tabID: pane.activeTabID,
            surfaceID: UUID(),
            message: firing.reminder.note,
            seen: false,
            kind: .reminder,
            reminderSetAt: firing.reminder.createdAt,
            reminderDueAt: firing.dueDate
        )
        bellFeed.record(entry)
        if SettingsPreference.resolvedSystemNotifications(defaults: preferences) {
            notifier?.postReminder(entry: entry, sessionTitle: session.title)
        }
    }
}
