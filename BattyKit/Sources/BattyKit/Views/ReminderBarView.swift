// ReminderBarView.swift

import SwiftUI

/// The Quick Reminder bar: a text field and a short list of times. Focus
/// stays in the text field; ↑/↓ move the highlight, Return commits the
/// highlighted time, ⌘1–⌘6 commit their row, Escape closes.
///
/// The model is seeded once from the store in `init` and mutated only from
/// key and click handlers; the store is written only when a commit runs.
struct ReminderBarView: View {
    let store: AppStateStore
    let session: SessionRuntime
    let focus: FocusState<ReminderBarField?>.Binding
    let onClose: () -> Void

    @State private var model: ReminderBarModel

    init(
        store: AppStateStore,
        session: SessionRuntime,
        focus: FocusState<ReminderBarField?>.Binding,
        onClose: @escaping () -> Void
    ) {
        self.store = store
        self.session = session
        self.focus = focus
        self.onClose = onClose
        _model = State(initialValue: ReminderBarModel(
            editing: session.reminder,
            suggestion: ReminderBarModel.suggestion(for: session),
            tomorrow: store.tomorrowReminderTime,
            now: store.reminderScheduler.now,
            calendar: store.reminderScheduler.calendar))
    }

    private var calendar: Calendar { store.reminderScheduler.calendar }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "alarm")
                    .foregroundStyle(.secondary)
                TextField("Remind me to…", text: $model.text)
                    .textFieldStyle(.plain)
                    .focused(focus, equals: .text)
                    .onKeyPress(.upArrow) { model.moveHighlight(-1); return .handled }
                    .onKeyPress(.downArrow) { model.moveHighlight(1); return .handled }
                    .onKeyPress(.return) { activate(model.highlightedRow); return .handled }
                    .onKeyPress(.escape) { escape(); return .handled }
                    .accessibilityIdentifier("reminder-bar.text")
                Text(session.title)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            switch model.mode {
            case .list:
                rowList
            case .picking:
                picker
            }

            Divider()

            HStack(spacing: 16) {
                Text("↩ Remind Me")
                Text("↑↓ Time")
                Text("esc Cancel")
                Spacer()
                if let count = model.countLabel {
                    Text(count)
                        .monospacedDigit()
                        .accessibilityIdentifier("reminder-bar.count")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .frame(width: 560)
        .background(.regularMaterial)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("reminder-bar")
        .onAppear { focus.wrappedValue = .text }
    }

    private var rowList: some View {
        let now = store.reminderScheduler.now
        return VStack(spacing: 0) {
            ForEach(Array(model.rows.enumerated()), id: \.element) { index, row in
                Button {
                    activate(row)
                } label: {
                    ReminderBarRowLabel(
                        title: title(for: row),
                        detail: detail(for: row, now: now),
                        hint: digit(for: row).map { "⌘\($0)" },
                        isDestructive: row == .remove,
                        isHighlighted: index == model.highlighted)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(digit(for: row).map {
                    KeyboardShortcut(KeyEquivalent(Character("\($0)")), modifiers: .command)
                })
                .accessibilityIdentifier("reminder-bar.row.\(row.accessibilitySuffix)")
            }
        }
        .padding(.vertical, 4)
    }

    private var picker: some View {
        let now = store.reminderScheduler.now
        let valid = model.pickedDateIsValid && ReminderSpec.isInstantInRange(model.pickedDate, now: now)
        return HStack(spacing: 12) {
            DatePicker(
                "Date and Time",
                selection: Binding(get: { model.pickedDate }, set: { model.setPickedDate($0) }),
                displayedComponents: [.date, .hourAndMinute]
            )
            .labelsHidden()
            .focused(focus, equals: .date)
            .onKeyPress(.return) { activate(.pick); return .handled }
            .onKeyPress(.escape) { escape(); return .handled }
            .accessibilityIdentifier("reminder-bar.picker")
            Text(valid
                ? String(localized: "Reminds you \(ReminderFormat.absolute(model.pickedDate, calendar: calendar))")
                : String(localized: "Choose a time between 1 minute and 7 days from now."))
                .font(.callout)
                .foregroundStyle(valid ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
                .accessibilityIdentifier("reminder-bar.summary")
            Spacer()
            Button("Set") { activate(.pick) }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("reminder-bar.pick.set")
            Button("Back") { escape() }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("reminder-bar.pick.back")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(digitShortcuts)
    }

    /// The picker replaces the rows that carry ⌘1–⌘6, so these keep the
    /// chords in the sheet; without them the main menu's ⌘-digit "Session N"
    /// items would take the key and switch Sessions behind the bar.
    private var digitShortcuts: some View {
        ForEach(1...6, id: \.self) { digit in
            Button("") {
                if let row = model.row(forCommandDigit: digit) { activate(row) }
            }
            .keyboardShortcut(KeyEquivalent(Character("\(digit)")), modifiers: .command)
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
        }
    }

    private func activate(_ row: ReminderBarRow) {
        model.highlight(row)
        let wasListing = model.mode == .list
        guard let commit = model.commit(row: row, now: store.reminderScheduler.now, calendar: calendar) else {
            if wasListing, model.mode == .picking {
                focus.wrappedValue = .date
            }
            return
        }
        ReminderActions.commit(commit, session: session, store: store)
        onClose()
    }

    private func escape() {
        if model.mode == .picking {
            model.mode = .list
            focus.wrappedValue = .text
        } else {
            onClose()
        }
    }

    private func digit(for row: ReminderBarRow) -> Int? {
        (1...6).first { model.row(forCommandDigit: $0) == row }
    }

    private func title(for row: ReminderBarRow) -> String {
        switch row {
        case .keep(let due):
            String(localized: "Keep \(ReminderFormat.time(due, calendar: calendar))")
        case .after(let minutes):
            ReminderActions.presetTitle(minutes: minutes)
        case .tomorrow:
            String(localized: "Tomorrow")
        case .pick:
            String(localized: "Pick Date & Time…")
        case .remove:
            String(localized: "Remove Reminder")
        }
    }

    private func detail(for row: ReminderBarRow, now: Date) -> String? {
        switch row {
        case .after(let minutes):
            ReminderFormat.time(now.addingTimeInterval(TimeInterval(minutes) * 60), calendar: calendar)
        case .tomorrow(let time):
            ReminderActions.tomorrowTimeText(time, calendar: calendar)
        case .keep, .pick, .remove:
            nil
        }
    }
}

private struct ReminderBarRowLabel: View {
    let title: String
    let detail: String?
    let hint: String?
    let isDestructive: Bool
    let isHighlighted: Bool

    var body: some View {
        HStack {
            Text(title)
                .foregroundStyle(isDestructive ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                .frame(maxWidth: .infinity, alignment: .leading)
            if let detail {
                Text(detail)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if let hint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 28, alignment: .trailing)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(isHighlighted ? Color.accentColor.opacity(0.2) : Color.clear)
        .contentShape(Rectangle())
    }
}

/// The bar presented in its own sheet (⇧⌘R, the menus, the Sidebar). Owns
/// the focus state the bar's field binds to.
struct ReminderBarSheetHost: View {
    let store: AppStateStore
    let session: SessionRuntime
    let onClose: () -> Void

    @FocusState private var focus: ReminderBarField?

    var body: some View {
        ReminderBarView(store: store, session: session, focus: $focus, onClose: onClose)
            .defaultFocus($focus, .text)
    }
}
