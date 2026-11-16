// ReminderMenu.swift

import SwiftUI

/// What each "Remind Me" entry point does. The Session menu, the Sidebar
/// row's context menu and the Command Palette all call these, so the three
/// can't drift apart. Every call is event-origin (a menu or palette action).
@MainActor
enum ReminderActions {
    static func presetTitle(minutes: Int) -> String {
        minutes == 60 ? String(localized: "In 1 Hour") : String(localized: "In \(minutes) Minutes")
    }

    static func tomorrowTitle(_ time: ReminderTime, calendar: Calendar, locale: Locale = .autoupdatingCurrent) -> String {
        String(localized: "Tomorrow at \(tomorrowTimeText(time, calendar: calendar, locale: locale))")
    }

    static func tomorrowTimeText(_ time: ReminderTime, calendar: Calendar, locale: Locale = .autoupdatingCurrent) -> String {
        var parts = DateComponents()
        parts.hour = time.hour
        parts.minute = time.minute
        guard let date = calendar.date(from: parts) else {
            return String(format: "%d:%02d", time.hour, time.minute)
        }
        return ReminderFormat.time(date, calendar: calendar, locale: locale)
    }

    /// Opens the Quick Reminder bar for `session`, in edit mode when it
    /// has a pending Reminder. Event-origin only: a menu item, a shortcut,
    /// the palette or a Sidebar click.
    static func openBar(for session: SessionRuntime, in window: WindowRuntime) {
        guard window.reminderBarSessionID != session.id else { return }
        window.reminderBarSessionID = session.id
    }

    /// Opens the bar from a menu item or chord, unless a sheet is attached
    /// to the Window. The item's key equivalent reaches the main menu while
    /// another sheet is key, and the bar would stack on that sheet.
    static func openBar(for session: SessionRuntime, in window: WindowRuntime, windowHasAttachedSheet: Bool) {
        guard !windowHasAttachedSheet else { return }
        openBar(for: session, in: window)
    }

    /// Opens the bar for the Window's selected Session, if it has one.
    static func openBar(in window: WindowRuntime) {
        guard let session = window.selectedSession else { return }
        openBar(for: session, in: window)
    }

    /// Runs a commit of the bar against the store.
    @discardableResult
    static func commit(_ commit: ReminderBarCommit, session: SessionRuntime, store: AppStateStore) -> ReminderBarOutcome {
        store.commitReminderBar(commit, forSessionID: session.id)
    }

    static func cancel(_ session: SessionRuntime, store: AppStateStore) {
        store.cancelReminder(forSessionID: session.id)
    }

    /// "Reminder at 3:45 PM", or "tomorrow at 9:00 AM", with the note when
    /// there is one.
    static func detail(for reminder: SessionReminder, store: AppStateStore) -> String? {
        let calendar = store.reminderScheduler.calendar
        guard let due = reminder.fireDate(calendar: calendar) else { return nil }
        let phrase = ReminderFormat.phrase(for: due, now: store.reminderScheduler.now, calendar: calendar)
        let base = String(localized: "Reminder \(phrase)")
        guard let note = reminder.note else { return base }
        return "\(base) \u{2014} \(note)"
    }
}

/// The Remind Me items for one Session: "Remind Me…", or "Edit Reminder…"
/// and "Cancel Reminder" while one is pending. Each opens the Quick
/// Reminder bar; none sets a Reminder without letting the user type.
///
/// `session` is what the items display and are enabled by. `target` is
/// resolved only when an item is chosen, because the Session menu's action
/// window depends on non-observed AppKit state (`BattyCommands.actionWindow`)
/// and is nil while an auxiliary window is key.
///
/// While a sheet is attached to the target Window the open items decline:
/// they stay enabled and consume their key equivalent but do nothing,
/// because `NSWindow.attachedSheet` is not observed and a `.disabled` driven
/// by it would not re-evaluate when the sheet closes. The Session menu's
/// `target` is already nil over a sheet (`AppStateStore.menuTargetWindow`);
/// the explicit check covers the Sidebar's explicit target.
struct ReminderMenuItems: View {
    let store: AppStateStore
    let session: SessionRuntime?
    var firstItemIdentifier: String?
    let target: () -> (window: WindowRuntime, session: SessionRuntime)?

    var body: some View {
        let shortcut = ShortcutsStore.shared.keyboardShortcut(for: .remindMe)
        if session?.reminder != nil {
            Button("Edit Reminder…") { open() }
                .keyboardShortcut(shortcut)
                .accessibilityIdentifier(firstItemIdentifier ?? "menu.remind.edit")
            Button("Cancel Reminder") {
                guard let target = target() else { return }
                ReminderActions.cancel(target.session, store: store)
            }
        } else {
            Button("Remind Me…") { open() }
                .keyboardShortcut(shortcut)
                .disabled(session == nil)
                .accessibilityIdentifier(firstItemIdentifier ?? "menu.remind.open")
        }
    }

    private func open() {
        guard let target = target() else { return }
        ReminderActions.openBar(
            for: target.session, in: target.window,
            windowHasAttachedSheet: store.windowHasAttachedSheet(target.window.id))
    }
}
