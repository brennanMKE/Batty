// ReminderSheet.swift

import SwiftUI

/// The sheet's choices, separate from the view so the rules (which choice is
/// selected, whether Set is enabled, what request it makes) are unit-testable.
struct ReminderDraft: Equatable {
    enum Choice: Equatable {
        case preset(Int)
        case custom
        case tomorrow
    }

    static let maxHours = 168

    var choice: Choice = .preset(15)
    var hours: Int = 0
    var minutes: Int = 0
    var tomorrowHour: Int = ReminderSpec.defaultTomorrowHour
    var tomorrowMinute: Int = ReminderSpec.defaultTomorrowMinute
    var note: String = ""

    /// A draft seeded from an existing Reminder, for editing: a Tomorrow
    /// Reminder reopens on Tomorrow at its time, an instant one on Custom
    /// with the time still left (at least a minute).
    /// `tomorrow` seeds the Tomorrow picker; a Tomorrow Reminder's own time
    /// overrides it.
    init(editing reminder: SessionReminder?, now: Date, tomorrow: ReminderTime = .defaultTomorrow) {
        tomorrowHour = tomorrow.hour
        tomorrowMinute = tomorrow.minute
        guard let reminder else { return }
        note = reminder.note ?? ""
        switch reminder.target {
        case .wallClock(let components):
            choice = .tomorrow
            tomorrowHour = components.hour ?? tomorrow.hour
            tomorrowMinute = components.minute ?? tomorrow.minute
        case .instant(let due):
            let remaining = max(ReminderSpec.minMinutes, Int((due.timeIntervalSince(now) / 60).rounded(.up)))
            let clamped = min(remaining, ReminderSpec.maxMinutes)
            choice = .custom
            hours = clamped / 60
            minutes = clamped % 60
        }
    }

    init(tomorrow: ReminderTime = .defaultTomorrow) {
        tomorrowHour = tomorrow.hour
        tomorrowMinute = tomorrow.minute
    }

    var spec: ReminderSpec? {
        let made: ReminderSpec
        switch choice {
        case .preset(let minutes): made = .after(minutes: minutes)
        case .custom: made = .after(minutes: hours * 60 + minutes)
        case .tomorrow: made = .tomorrow(hour: tomorrowHour, minute: tomorrowMinute)
        }
        return made.isValid ? made : nil
    }

    var canSet: Bool {
        guard (0...Self.maxHours).contains(hours), (0...59).contains(minutes) else { return false }
        return spec != nil
    }
}

struct ReminderSheet: View {
    let store: AppStateStore
    let session: SessionRuntime
    let onClose: () -> Void

    @State private var draft: ReminderDraft
    @FocusState private var noteFocused: Bool

    private let isEditing: Bool

    init(store: AppStateStore, session: SessionRuntime, onClose: @escaping () -> Void) {
        self.store = store
        self.session = session
        self.onClose = onClose
        self.isEditing = session.reminder != nil
        _draft = State(initialValue: ReminderDraft(
            editing: session.reminder, now: store.reminderScheduler.now, tomorrow: store.tomorrowReminderTime))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Remind Me About \u{201C}\(session.title)\u{201D}")
                .font(.headline)
                .lineLimit(2)
                .accessibilityIdentifier("reminder-sheet.title")

            presetRow
            customRow
            tomorrowRow

            VStack(alignment: .leading, spacing: 4) {
                Text("Note (optional)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Note", text: $draft.note, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)
                    .focused($noteFocused)
                    .accessibilityIdentifier("reminder-sheet.note")
                    .onChange(of: draft.note) { _, new in
                        if new.count > SessionReminder.maxNoteLength {
                            draft.note = String(new.prefix(SessionReminder.maxNoteLength))
                        }
                    }
            }

            Text(summary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("reminder-sheet.summary")

            HStack {
                if isEditing {
                    Button("Remove Reminder", role: .destructive) {
                        store.cancelReminder(forSessionID: session.id)
                        onClose()
                    }
                    .accessibilityIdentifier("reminder-sheet.remove")
                }
                Spacer()
                Button("Cancel", role: .cancel, action: onClose)
                    .keyboardShortcut(.escape)
                    .accessibilityIdentifier("reminder-sheet.cancel")
                Button(isEditing ? "Update Reminder" : "Set Reminder", action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!draft.canSet)
                    .accessibilityIdentifier("reminder-sheet.set")
            }
        }
        .padding(20)
        .frame(width: 400)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("reminder-sheet")
    }

    private var presetRow: some View {
        HStack(spacing: 8) {
            ForEach(ReminderSpec.presetMinutes, id: \.self) { minutes in
                Toggle(isOn: Binding(
                    get: { draft.choice == .preset(minutes) },
                    set: { if $0 { draft.choice = .preset(minutes) } }
                )) {
                    Text(Self.presetTitle(minutes))
                }
                .toggleStyle(.button)
                .accessibilityIdentifier("reminder-sheet.preset.\(minutes)")
            }
        }
    }

    private var customRow: some View {
        HStack(spacing: 6) {
            Toggle(isOn: Binding(
                get: { draft.choice == .custom },
                set: { if $0 { draft.choice = .custom } }
            )) {
                Text("Custom")
            }
            .toggleStyle(.button)
            .accessibilityIdentifier("reminder-sheet.custom")
            TextField("0", value: $draft.hours, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 52)
                .multilineTextAlignment(.trailing)
                .onChange(of: draft.hours) { _, _ in draft.choice = .custom }
                .accessibilityIdentifier("reminder-sheet.custom.hours")
            Text("h")
            TextField("0", value: $draft.minutes, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 52)
                .multilineTextAlignment(.trailing)
                .onChange(of: draft.minutes) { _, _ in draft.choice = .custom }
                .accessibilityIdentifier("reminder-sheet.custom.minutes")
            Text("m")
        }
    }

    private var tomorrowRow: some View {
        HStack(spacing: 8) {
            Toggle(isOn: Binding(
                get: { draft.choice == .tomorrow },
                set: { if $0 { draft.choice = .tomorrow } }
            )) {
                Text("Tomorrow")
            }
            .toggleStyle(.button)
            .accessibilityIdentifier("reminder-sheet.tomorrow")
            DatePicker(
                "Time",
                selection: tomorrowTime,
                displayedComponents: .hourAndMinute
            )
            .labelsHidden()
            .accessibilityIdentifier("reminder-sheet.tomorrow-time")
        }
    }

    /// The picker edits a `Date`; the draft keeps the hour and minute, which
    /// is all a Tomorrow Reminder stores.
    private var tomorrowTime: Binding<Date> {
        Binding(
            get: {
                let calendar = store.reminderScheduler.calendar
                var parts = calendar.dateComponents([.year, .month, .day], from: store.reminderScheduler.now)
                parts.hour = draft.tomorrowHour
                parts.minute = draft.tomorrowMinute
                return calendar.date(from: parts) ?? store.reminderScheduler.now
            },
            set: { date in
                let parts = store.reminderScheduler.calendar.dateComponents([.hour, .minute], from: date)
                draft.tomorrowHour = parts.hour ?? draft.tomorrowHour
                draft.tomorrowMinute = parts.minute ?? draft.tomorrowMinute
                draft.choice = .tomorrow
            }
        )
    }

    private var summary: String {
        let calendar = store.reminderScheduler.calendar
        guard let spec = draft.spec,
              let due = spec.makeReminder(now: store.reminderScheduler.now, calendar: calendar, note: nil)?
                  .fireDate(calendar: calendar)
        else {
            return String(localized: "Choose a time between 1 minute and 7 days from now.")
        }
        return String(localized: "Reminds you \(ReminderFormat.absolute(due, calendar: calendar))")
    }

    private func commit() {
        guard let spec = draft.spec else { return }
        store.commitReminderSheet(spec, note: draft.note, forSessionID: session.id)
        onClose()
    }

    static func presetTitle(_ minutes: Int) -> String {
        minutes == 60 ? String(localized: "1 hour") : String(localized: "\(minutes) min")
    }
}
