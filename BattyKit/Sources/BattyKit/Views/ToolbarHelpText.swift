// ToolbarHelpText.swift

import Foundation

/// Toolbar tooltips built from the live shortcut bindings, so a rebinding in
/// Settings → Shortcuts shows up in the tooltip.
enum ToolbarHelpText {
    static func labelled(_ title: String, _ binding: ShortcutBinding) -> String {
        "\(title) (\(binding.displayString))"
    }

    static func bellFeed(_ shortcuts: ShortcutsStore) -> String {
        labelled(String(localized: "Bell Feed"), shortcuts.binding(for: .toggleBellFeed))
    }

    static func reminders(
        _ shortcuts: ShortcutsStore,
        list: RemindersListModel,
        now: Date,
        calendar: Calendar,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        let title = labelled(String(localized: "Reminders"), shortcuts.binding(for: .toggleReminders))
        guard !list.isEmpty else { return title }
        let summary: String
        if !list.due.isEmpty {
            summary = list.upcoming.isEmpty
                ? String(localized: "\(list.due.count) due")
                : String(localized: "\(list.due.count) due, \(list.upcoming.count) upcoming")
        } else if let next = list.upcoming.first?.dueAt {
            let phrase = ReminderFormat.phrase(for: next, now: now, calendar: calendar, locale: locale)
            summary = String(localized: "\(list.upcoming.count) upcoming, next \(phrase)")
        } else {
            summary = String(localized: "\(list.upcoming.count) upcoming")
        }
        return "\(title) \u{00B7} \(summary)"
    }

    static func splitHorizontal(_ shortcuts: ShortcutsStore) -> String {
        let split = labelled(String(localized: "Split Horizontally"), shortcuts.binding(for: .splitHorizontal))
        let column = labelled(
            String(localized: "Option for a full-height column"),
            shortcuts.binding(for: .splitFullHeightColumn)
        )
        return "\(split) \u{2014} \(column)"
    }

    static func splitVertical(_ shortcuts: ShortcutsStore) -> String {
        let split = labelled(String(localized: "Split Vertically"), shortcuts.binding(for: .splitVertical))
        let row = labelled(
            String(localized: "Option for a full-width row"),
            shortcuts.binding(for: .splitFullWidthRow)
        )
        return "\(split) \u{2014} \(row)"
    }
}
