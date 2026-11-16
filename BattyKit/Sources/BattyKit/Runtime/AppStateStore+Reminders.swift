// AppStateStore+Reminders.swift

import Foundation
import os

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "AppStateStoreReminders")

extension AppStateStore {
    /// The default for every Tomorrow request that names no time: the
    /// one-click Tomorrow item and `batty session remind --tomorrow`.
    public var tomorrowReminderSpec: ReminderSpec { tomorrowReminderTime.tomorrowSpec }

    func rememberTomorrowReminderTime(_ time: ReminderTime) {
        guard time != tomorrowReminderTime else { return }
        tomorrowReminderTime = time
        SettingsPreference.storeReminderTomorrowTime(time, defaults: preferences)
    }

    /// A commit of the Quick Reminder bar. A Pick Date & Time… instant on
    /// the next calendar day also becomes the remembered Tomorrow time;
    /// the CLI's `remindSessionForXPC` never changes it. Keep and Remove act
    /// only on the Reminder they name, never on one that replaced it.
    @discardableResult
    func commitReminderBar(_ commit: ReminderBarCommit, forSessionID sessionID: UUID) -> ReminderBarOutcome {
        switch commit {
        case .set(let spec, let note):
            let result = setReminder(spec, note: note, forSessionID: sessionID)
            if result != nil, case .at(let date) = spec {
                let calendar = reminderScheduler.calendar
                if let tomorrow = calendar.date(byAdding: .day, value: 1, to: reminderScheduler.now),
                   calendar.isDate(date, inSameDayAs: tomorrow) {
                    let parts = calendar.dateComponents([.hour, .minute], from: date)
                    rememberTomorrowReminderTime(ReminderTime(hour: parts.hour ?? 0, minute: parts.minute ?? 0))
                }
            }
            return result.map(ReminderBarOutcome.saved) ?? .rejected
        case .keep(let reminderID, let note):
            if let kept = updateReminderNote(note, reminderID: reminderID, forSessionID: sessionID) {
                return .saved(kept)
            }
            return .reminderGone(fired: remindersFiredThisLaunch.contains(reminderID))
        case .remove(let reminderID):
            if cancelReminder(id: reminderID, forSessionID: sessionID) {
                return .removed
            }
            return .reminderGone(fired: remindersFiredThisLaunch.contains(reminderID))
        }
    }

    /// Changes only the pending Reminder's text: its id, creation time and
    /// due instant stay, and its system request is replaced under the same
    /// identifier. Nil, writing nothing, when that Reminder is no longer
    /// pending on the Session.
    @discardableResult
    public func updateReminderNote(_ note: String?, reminderID: UUID, forSessionID sessionID: UUID) -> SessionReminder? {
        guard let session = session(id: sessionID), var existing = session.reminder, existing.id == reminderID else {
            logger.notice("updateReminderNote: reminder \(reminderID, privacy: .public) not pending for session \(sessionID, privacy: .public) (pending: \(self.session(id: sessionID)?.reminder?.id.uuidString ?? "none", privacy: .public))")
            return nil
        }
        existing.note = SessionReminder.normalizedNote(note)
        session.reminder = existing
        reminderScheduler.set(existing, forSessionID: sessionID)
        scheduleSystemReminder(existing, session: session)
        return existing
    }

    /// A notification's Remind Again action: a new Reminder on the same
    /// Session with the same text, `minutes` from now. Applies only when the
    /// Session has no pending Reminder other than the banner's own; a newer
    /// pending Reminder is left alone. The fired entry is marked seen and kept.
    func remindAgain(minutes: Int, payload: NotificationTapPayload) {
        guard let sessionID = payload.sessionID, let session = session(id: sessionID) else {
            logger.notice("remindAgain: session \(payload.sessionID?.uuidString ?? "nil", privacy: .public) is gone; ignoring")
            return
        }
        defer {
            if let entryID = payload.entryID {
                markBellSeen(id: entryID)
            }
        }
        if let pending = session.reminder, pending.id != payload.reminderID {
            logger.notice("remindAgain: session \(sessionID, privacy: .public) has a newer pending reminder \(pending.id, privacy: .public); ignoring banner for \(payload.reminderID?.uuidString ?? "nil", privacy: .public)")
            return
        }
        setReminder(.after(minutes: minutes), note: payload.note, forSessionID: sessionID)
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
        let previousID = session.reminder?.id
        session.reminder = reminder
        reminderScheduler.set(reminder, forSessionID: sessionID)
        if let previousID, previousID != reminder.id {
            notifier?.removeScheduledReminders(ids: [previousID])
        }
        scheduleSystemReminder(reminder, session: session)
        return reminder
    }

    /// Removes the Session's pending Reminder at once, with no confirmation.
    public func cancelReminder(forSessionID sessionID: UUID) {
        session(id: sessionID)?.reminder = nil
        cancelReminderState(sessionID: sessionID, keepSystemRequest: false)
    }

    /// Cancels the Session's pending Reminder only when it is `reminderID`.
    /// False, cancelling nothing, otherwise.
    @discardableResult
    func cancelReminder(id reminderID: UUID, forSessionID sessionID: UUID) -> Bool {
        guard session(id: sessionID)?.reminder?.id == reminderID else {
            logger.notice("cancelReminder: reminder \(reminderID, privacy: .public) not pending for session \(sessionID, privacy: .public)")
            return false
        }
        cancelReminder(forSessionID: sessionID)
        return true
    }

    /// Cancels the in-app Reminder and, unless `keepSystemRequest`, its
    /// scheduled system request. Reads the id from the scheduler because
    /// `WindowRuntime.removeSession` clears `session.reminder` first.
    func cancelReminderState(sessionID: UUID, keepSystemRequest: Bool) {
        if !keepSystemRequest, let id = reminderScheduler.reminder(forSessionID: sessionID)?.id {
            notifier?.removeScheduledReminders(ids: [id])
        }
        reminderScheduler.cancel(sessionID: sessionID)
    }

    /// Nothing is scheduled with the system under the UI-test manual clock:
    /// a trigger computed from a frozen clock would put real banners in the
    /// test machine's Notification Center.
    private var schedulesSystemReminders: Bool {
        SettingsPreference.resolvedSystemNotifications(defaults: preferences)
            && reminderScheduler.manualClock == nil
    }

    private func scheduleSystemReminder(_ reminder: SessionReminder, session: SessionRuntime) {
        guard let notifier else { return }
        guard reminderScheduler.manualClock == nil else {
            logger.debug("scheduleSystemReminder: manual clock; not scheduling \(reminder.id, privacy: .public)")
            return
        }
        guard SettingsPreference.resolvedSystemNotifications(defaults: preferences) else { return }
        notifier.scheduleReminder(.make(
            reminder: reminder,
            sessionTitle: session.title,
            projectID: session.projectID,
            playSound: SettingsPreference.resolvedBellSound(defaults: preferences)
        ))
    }

    /// Called when "Show system notifications" flips. Off removes every
    /// scheduled Reminder request, orphans from earlier launches included;
    /// on schedules every pending Reminder.
    public func systemNotificationsSettingChanged() {
        guard let notifier else { return }
        guard SettingsPreference.resolvedSystemNotifications(defaults: preferences) else {
            notifier.removeAllScheduledReminders()
            return
        }
        for window in windows {
            for session in window.sessions {
                if let reminder = session.reminder {
                    scheduleSystemReminder(reminder, session: session)
                }
            }
        }
    }

    /// Whether a Reminder with this id is still pending in some Session.
    public func isLiveReminder(id: UUID) -> Bool {
        windows.contains { window in
            window.sessions.contains { $0.reminder?.id == id }
        }
    }

    /// Whether a quit leaves pending Reminders scheduled with the system.
    public var remindersStillNotifyAfterQuit: Bool { schedulesSystemReminders }

    /// The `willPresent` decision. A suppressed live delivery means the
    /// system got there before the in-app loop (e.g. App Nap), so the
    /// scheduler is re-evaluated and fires the one banner now. A delivery
    /// for a Reminder already fired in-app this launch is a duplicate.
    func presentNotification(_ payload: NotificationTapPayload) -> Bool {
        let live = payload.reminderID.map { isLiveReminder(id: $0) } ?? false
        let fired = payload.reminderID.map { remindersFiredThisLaunch.contains($0) } ?? false
        let show = ScheduledReminderNotification.shouldPresent(
            payload: payload,
            isLiveReminder: live,
            alreadyFiredInApp: fired,
            systemNotificationsEnabled: SettingsPreference.resolvedSystemNotifications(defaults: preferences)
        )
        if !show && live {
            reminderScheduler.reevaluate()
        }
        return show
    }

    func notificationTapRoute(for payload: NotificationTapPayload) -> NotificationTapRoute {
        if let entryID = payload.entryID, bellFeed.entries.contains(where: { $0.id == entryID }) {
            return .jumpToEntry(entryID)
        }
        if let projectID = payload.projectID, projectStore.project(id: projectID) != nil {
            return .openProject(projectID)
        }
        return .activateOnly
    }

    /// A tap on any Batty notification. Batty itself is activated by the
    /// notifier delegate.
    public func handleNotificationTap(_ payload: NotificationTapPayload) {
        if case .remindAgain(let minutes) = payload.action {
            remindAgain(minutes: minutes, payload: payload)
            return
        }
        switch notificationTapRoute(for: payload) {
        case .jumpToEntry(let id):
            guard let entry = bellFeed.entries.first(where: { $0.id == id }) else { return }
            markBellSeen(id: id)
            jumpToBellEntry(entry)
        case .openProject(let id):
            requestOpenProject(id: id, mode: .focusExistingOrOpen)
        case .activateOnly:
            if let reminderID = payload.reminderID {
                let why = payload.projectID == nil ? "no project" : "project gone"
                logger.notice("handleNotificationTap: reminder \(reminderID, privacy: .public) has no live Session (\(why, privacy: .public)); activating only")
            } else if payload.entryID != nil {
                logger.notice("handleNotificationTap: entry is no longer in the Bell Feed; activating only")
            }
        }
    }

    /// Builds the system notifier once, wired to this store. Called from the
    /// app delegate before launch finishes; a no-op when a notifier (e.g. a
    /// test spy) is already set.
    public func installNotifier() {
        guard notifier == nil else { return }
        let notifier = BellNotifier(
            onTap: { [weak self] payload in self?.handleNotificationTap(payload) },
            presentation: { [weak self] payload in self?.presentNotification(payload) ?? true }
        )
        self.notifier = notifier
        notifier.ensureAuthorization()
    }

    public enum SessionRemindOutcome: Equatable {
        case set(SessionReminder, sessionID: UUID)
        case cancelled(sessionID: UUID)
        case unknownSession
        case noSessionToTarget
        case invalidSpec
    }

    /// The `sessionRemind` XPC verb. Always a fresh `setReminder` (never
    /// the remembered-time write); cancel is idempotent.
    public func remindSessionForXPC(_ request: SessionRemindRequest) -> SessionRemindOutcome {
        guard let sessionID = request.sessionID ?? focusedSessionIDFallback() else {
            return .noSessionToTarget
        }
        guard session(id: sessionID) != nil else { return .unknownSession }
        let spec: ReminderSpec
        switch request.action {
        case .cancel:
            cancelReminder(forSessionID: sessionID)
            return .cancelled(sessionID: sessionID)
        case .after(let minutes):
            spec = .after(minutes: minutes)
        case .tomorrow(nil):
            spec = tomorrowReminderSpec
        case .tomorrow(let time?):
            spec = .tomorrow(hour: time.hour, minute: time.minute)
        case .today(let time):
            guard let date = ReminderSpec.todayAt(
                hour: time.hour, minute: time.minute,
                now: reminderScheduler.now, calendar: reminderScheduler.calendar)
            else { return .invalidSpec }
            spec = .at(date)
        }
        guard spec.isValid, let reminder = setReminder(spec, note: request.note, forSessionID: sessionID) else {
            return .invalidSpec
        }
        return .set(reminder, sessionID: sessionID)
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
        remindersFiredThisLaunch.insert(firing.reminder.id)
        notifier?.removeScheduledReminders(ids: [firing.reminder.id])
        if SettingsPreference.resolvedSystemNotifications(defaults: preferences) {
            notifier?.postReminder(
                entry: entry,
                reminderID: firing.reminder.id,
                projectID: session.projectID,
                sessionTitle: session.title
            )
        }
    }
}
