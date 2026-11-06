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

    static var tomorrowTitle: String {
        String(localized: "Tomorrow at \(defaultTomorrowTimeText())")
    }

    static func defaultTomorrowTimeText(calendar: Calendar = .current) -> String {
        var parts = DateComponents()
        parts.hour = ReminderSpec.defaultTomorrowHour
        parts.minute = ReminderSpec.defaultTomorrowMinute
        guard let date = calendar.date(from: parts) else { return "9:00 AM" }
        return ReminderFormat.time(date, calendar: calendar)
    }

    /// A preset sets the Reminder at once, with no note. It replaces any
    /// Reminder the Session already had, note included.
    static func set(_ spec: ReminderSpec, on session: SessionRuntime, store: AppStateStore) {
        store.setReminder(spec, note: nil, forSessionID: session.id)
    }

    static func presentSheet(for session: SessionRuntime, in window: WindowRuntime) {
        window.reminderSheetSessionID = session.id
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

/// The "Remind Me" submenu for one Session: five one-click choices and
/// Custom…, plus the pending Reminder's status, Edit and Cancel when it
/// has one.
///
/// `session` is what the menu displays and is enabled by. `target` is
/// resolved only when an item is chosen, because the Session menu's action
/// window depends on non-observed AppKit state (`BattyCommands.actionWindow`)
/// and is nil while an auxiliary window is key.
struct ReminderMenu: View {
    let store: AppStateStore
    let session: SessionRuntime?
    let target: () -> (window: WindowRuntime, session: SessionRuntime)?

    var body: some View {
        Menu {
            ForEach(ReminderSpec.presetMinutes, id: \.self) { minutes in
                Button(ReminderActions.presetTitle(minutes: minutes)) {
                    guard let target = target() else { return }
                    ReminderActions.set(.after(minutes: minutes), on: target.session, store: store)
                }
            }
            Button(ReminderActions.tomorrowTitle) {
                guard let target = target() else { return }
                ReminderActions.set(.defaultTomorrow, on: target.session, store: store)
            }
            Button("Custom…") {
                guard let target = target() else { return }
                ReminderActions.presentSheet(for: target.session, in: target.window)
            }
            if let reminder = session?.reminder {
                Divider()
                if let detail = ReminderActions.detail(for: reminder, store: store) {
                    Button(detail) {}
                        .disabled(true)
                }
                Button("Edit Reminder…") {
                    guard let target = target() else { return }
                    ReminderActions.presentSheet(for: target.session, in: target.window)
                }
                Button("Cancel Reminder") {
                    guard let target = target() else { return }
                    ReminderActions.cancel(target.session, store: store)
                }
            }
        } label: {
            Label("Remind Me", systemImage: "clock")
        }
        .disabled(session == nil)
    }
}
