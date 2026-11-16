// ReminderBarModel.swift

import Foundation

/// One choice in the Quick Reminder bar's time list.
enum ReminderBarRow: Equatable, Hashable {
    /// Edit mode only: keep the pending Reminder's due instant.
    case keep(Date)
    case after(Int)
    case tomorrow(ReminderTime)
    case pick
    /// Edit mode only.
    case remove

    var accessibilitySuffix: String {
        switch self {
        case .keep: "keep"
        case .after(let minutes): "\(minutes)"
        case .tomorrow: "tomorrow"
        case .pick: "pick"
        case .remove: "remove"
        }
    }
}

enum ReminderBarMode: Equatable {
    case list
    case picking
}

/// What a commit of the bar asks the store to do.
enum ReminderBarCommit: Equatable {
    case set(ReminderSpec, note: String?)
    /// Change only the text of the Reminder the bar was opened on.
    case keep(reminderID: UUID, note: String?)
    /// Cancel the Reminder the bar was opened on.
    case remove(reminderID: UUID)
}

/// What the store did with a commit of the bar.
enum ReminderBarOutcome: Equatable {
    /// A set or a keep.
    case saved(SessionReminder)
    case removed
    /// The Reminder a keep or remove named is no longer pending: it fired,
    /// was cancelled, or was replaced.
    case reminderGone(fired: Bool)
    /// A set whose Session is gone or whose spec is out of bounds.
    case rejected

    var reminder: SessionReminder? {
        if case .saved(let reminder) = self { reminder } else { nil }
    }
}

/// Why an edit-mode bar became a new-Reminder bar.
enum ReminderBarNotice: Equatable {
    case fired
    case changed
}

/// Which control of the bar holds keyboard focus.
enum ReminderBarField: Hashable {
    case text
    case date
}

/// The Quick Reminder bar's state: the text, the time rows, the highlight
/// and the Pick Date & Time… picker. A pure value, mutated only from the
/// bar's key and click handlers, so every rule is unit-testable.
struct ReminderBarModel: Equatable {
    static let countThreshold = 400

    private(set) var rows: [ReminderBarRow]
    private(set) var highlighted: Int
    var mode: ReminderBarMode = .list
    var pickedDate: Date
    /// False after a commit of an out-of-range picked date; drives the red
    /// summary. Reset when the picked date changes.
    private(set) var pickedDateIsValid = true
    private(set) var isEditing: Bool
    /// The Reminder an edit-mode bar was opened on; Keep and Remove act on
    /// it and nothing else.
    private(set) var editingReminderID: UUID?
    private(set) var notice: ReminderBarNotice?

    private var storage: String

    var text: String {
        get { storage }
        set {
            storage = newValue.count > SessionReminder.maxNoteLength
                ? String(newValue.prefix(SessionReminder.maxNoteLength))
                : newValue
        }
    }

    init(
        editing reminder: SessionReminder?,
        suggestion: String?,
        tomorrow: ReminderTime,
        now: Date,
        calendar: Calendar
    ) {
        let timeRows: [ReminderBarRow] = ReminderSpec.presetMinutes.map { .after($0) } + [.tomorrow(tomorrow), .pick]
        if let reminder, let due = reminder.fireDate(calendar: calendar) {
            isEditing = true
            editingReminderID = reminder.id
            rows = [.keep(due)] + timeRows + [.remove]
            highlighted = 0
            storage = reminder.note ?? ""
        } else {
            isEditing = false
            editingReminderID = nil
            rows = timeRows
            highlighted = timeRows.firstIndex(of: .after(15)) ?? 0
            storage = suggestion ?? ""
        }
        pickedDate = Self.defaultPickedDate(now: now, calendar: calendar)
    }

    var highlightedRow: ReminderBarRow { rows[highlighted] }

    /// "437 / 500", only past `countThreshold` characters.
    var countLabel: String? {
        guard text.count > Self.countThreshold else { return nil }
        return "\(text.count) / \(SessionReminder.maxNoteLength)"
    }

    mutating func moveHighlight(_ delta: Int) {
        guard !rows.isEmpty else { return }
        highlighted = ((highlighted + delta) % rows.count + rows.count) % rows.count
    }

    mutating func highlight(_ row: ReminderBarRow) {
        if let index = rows.firstIndex(of: row) { highlighted = index }
    }

    /// ⌘1–⌘6 name the six time rows, in both modes.
    func row(forCommandDigit digit: Int) -> ReminderBarRow? {
        let timeRows = rows.filter {
            switch $0 {
            case .keep, .remove: false
            default: true
            }
        }
        guard (1...timeRows.count).contains(digit) else { return nil }
        return timeRows[digit - 1]
    }

    /// The Reminder a Keep named is no longer pending: the bar becomes a
    /// new-Reminder bar with the typed text kept.
    mutating func markReminderGone(fired: Bool) {
        rows = rows.filter {
            switch $0 {
            case .keep, .remove: false
            default: true
            }
        }
        highlighted = rows.firstIndex(of: .after(15)) ?? 0
        isEditing = false
        editingReminderID = nil
        mode = .list
        notice = fired ? .fired : .changed
    }

    mutating func setPickedDate(_ date: Date) {
        pickedDate = date
        pickedDateIsValid = true
    }

    /// The store request for `row`, or nil when it commits nothing yet:
    /// Pick in the list opens the picker, and an out-of-range picked date
    /// marks the picker invalid.
    mutating func commit(row: ReminderBarRow, now: Date, calendar: Calendar) -> ReminderBarCommit? {
        let note = SessionReminder.normalizedNote(text)
        switch row {
        case .keep:
            guard let editingReminderID else { return nil }
            return .keep(reminderID: editingReminderID, note: note)
        case .after(let minutes):
            return .set(.after(minutes: minutes), note: note)
        case .tomorrow(let time):
            return .set(time.tomorrowSpec, note: note)
        case .remove:
            guard let editingReminderID else { return nil }
            return .remove(reminderID: editingReminderID)
        case .pick:
            guard mode == .picking else {
                mode = .picking
                return nil
            }
            guard ReminderSpec.isInstantInRange(pickedDate, now: now) else {
                pickedDateIsValid = false
                return nil
            }
            return .set(.at(pickedDate), note: note)
        }
    }

    /// Now plus an hour, rounded up to the next five minutes.
    static func defaultPickedDate(now: Date, calendar: Calendar) -> Date {
        let hourLater = now.addingTimeInterval(3600)
        let parts = calendar.dateComponents([.minute, .second, .nanosecond], from: hourLater)
        let minute = parts.minute ?? 0
        let past = (minute % 5) * 60 + (parts.second ?? 0)
        let rounded = hourLater.addingTimeInterval(-TimeInterval(past) - Double(parts.nanosecond ?? 0) / 1e9)
        return past == 0 && (parts.nanosecond ?? 0) == 0 ? hourLater : rounded.addingTimeInterval(300)
    }

    /// "Check on <command>" when the Session's focused terminal Pane is
    /// running one.
    @MainActor
    static func suggestion(for session: SessionRuntime) -> String? {
        guard let command = session.focusedTerminalPane?.activeTab?.runningCommandDisplayName,
              !command.isEmpty
        else { return nil }
        return String(localized: "Check on \(command)")
    }
}
