// RemindersView.swift

import SwiftUI

/// The Reminders popover: fired Reminders (Due) then pending ones
/// (Upcoming). Every store write here comes from a click or a key press;
/// opening the popover or moving the selection marks nothing read.
struct RemindersView: View {
    let store: AppStateStore
    let windowRuntime: WindowRuntime
    let onDismiss: () -> Void

    @State private var selection: RemindersRowID?
    @State private var hovered: RemindersRowID?

    var body: some View {
        let list = RemindersListModel.current(in: store)
        VStack(spacing: 0) {
            header
            Divider()
            if list.isEmpty {
                emptyState
            } else {
                listView(list)
            }
        }
        .frame(width: 360, height: 420)
        // Escape from the empty state, where no List holds focus.
        .onExitCommand { onDismiss() }
        .onAppear {
            // Only this view's own selection, never store state.
            if selection == nil { selection = list.initialSelection }
        }
    }

    // MARK: - Header and empty state

    private var header: some View {
        HStack {
            Text("Reminders")
                .font(.headline)
            Spacer()
            Button {
                newReminder()
            } label: {
                Label("New Reminder…", systemImage: "plus")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .disabled(windowRuntime.selectedSession == nil)
            .accessibilityIdentifier("reminders.new")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Reminders", systemImage: "alarm")
        } description: {
            Text("Set one on a Session to be brought back to it later.")
        } actions: {
            if let session = windowRuntime.selectedSession {
                Button {
                    newReminder()
                } label: {
                    HStack(spacing: 6) {
                        Text("New Reminder for \(session.title)…")
                        Text(ShortcutsStore.shared.binding(for: .remindMe).displayString)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("reminders.empty.new")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("reminders.empty")
    }

    // MARK: - List

    private func listView(_ list: RemindersListModel) -> some View {
        List(selection: $selection) {
            if !list.due.isEmpty {
                Section {
                    ForEach(list.due, id: \.id) { row in
                        dueRow(row)
                    }
                } header: {
                    HStack {
                        Text("Due")
                        Text(verbatim: "\(list.due.count)")
                            .foregroundStyle(.secondary)
                        Spacer()
                        ReadStateHeaderActions(
                            unreadCount: list.unreadCount,
                            readCount: list.readCount,
                            identifierPrefix: "reminders",
                            markAllRead: { store.markAllRemindersRead() },
                            clearRead: { act { store.clearReadReminders() } }
                        )
                    }
                }
            }
            if !list.upcoming.isEmpty {
                Section {
                    ForEach(list.upcoming, id: \.id) { row in
                        upcomingRow(row)
                    }
                } header: {
                    HStack {
                        Text("Upcoming")
                        Text(verbatim: "\(list.upcoming.count)")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listStyle(.plain)
        .accessibilityIdentifier("reminders.list")
        .background { keyEquivalents(list) }
        .onKeyPress(.upArrow) { press(.up) }
        .onKeyPress(.downArrow) { press(.down) }
        .onKeyPress(.return) { press(.open) }
        .onKeyPress(.escape) {
            onDismiss()
            return .handled
        }
        .onKeyPress(.delete) { press(.delete) }
        .onKeyPress(characters: CharacterSet(charactersIn: "eErR")) { keyPress in
            guard keyPress.modifiers.isDisjoint(with: [.command, .control, .option]) else { return .ignored }
            return press(keyPress.characters.lowercased() == "e" ? .edit : .remindAgain)
        }
    }

    /// Focus can sit on a header button instead of the List (it opens on
    /// New Reminder… with keyboard navigation on), and then the List's
    /// `onKeyPress` handlers never see a key. Key equivalents reach the
    /// popover's window whatever holds focus; the handlers above stay for
    /// when the List does. A disabled button lets its key through.
    private func keyEquivalents(_ list: RemindersListModel) -> some View {
        ZStack {
            ForEach(RemindersListKey.allCases, id: \.self) { key in
                Button("") { _ = perform(key) }
                    .keyboardShortcut(key.keyEquivalent, modifiers: [])
                    .disabled(list.action(for: key, selection: selection) == nil)
                    .focusable(false)
            }
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func press(_ key: RemindersListKey) -> KeyPress.Result {
        perform(key) ? .handled : .ignored
    }

    /// Reads the rows at key time. In the VM, a key-equivalent button ran an
    /// action closure from an earlier body evaluation, so rows captured in
    /// it were stale after Remind Again replaced a row.
    private func perform(_ key: RemindersListKey) -> Bool {
        let list = RemindersListModel.current(in: store)
        guard let action = list.action(for: key, selection: selection) else { return false }
        switch action {
        case .select(let id): selection = id
        case .open(let sessionID): openSession(sessionID)
        case .done(let row): done(row)
        case .cancel(let row): cancel(row)
        case .edit(let row): edit(row)
        case .remindAgain(let row): remindAgain(row, minutes: 15)
        }
        return true
    }

    private func dueRow(_ row: RemindersDueRow) -> some View {
        let title = row.sessionTitle
        return RemindersDueRowView(
            row: row,
            showsActions: hovered == row.id || selection == row.id,
            clock: clock,
            onRemindAgain: { remindAgain(row, minutes: $0) },
            onDone: { done(row) },
            summary: RemindersRowAccessibility(
                identifier: "reminders-due.\(title)",
                label: dueAccessibilityLabel(row),
                value: row.isUnread ? "reminder due, unread" : "reminder due, read",
                actions: [
                    .init(name: "Open Session") { openSession(row.sessionID) },
                    .init(name: "Remind Again in 15 Minutes") {
                        if row.canRemindAgain { remindAgain(row, minutes: 15) }
                    },
                    .init(name: "Remind Again in 1 Hour") {
                        if row.canRemindAgain { remindAgain(row, minutes: 60) }
                    },
                    .init(name: "Done") { done(row) },
                ])
        )
        .tag(row.id)
        .contentShape(Rectangle())
        .onTapGesture { openSession(row.sessionID) }
        .onHover { hover(row.id, $0) }
        .contextMenu {
            Button("Open Session") { openSession(row.sessionID) }
            Button("Remind Again in 15 Minutes") { remindAgain(row, minutes: 15) }
                .disabled(!row.canRemindAgain)
            Button("Remind Again in 1 Hour") { remindAgain(row, minutes: 60) }
                .disabled(!row.canRemindAgain)
            Button("Done") { done(row) }
        }
    }

    private func upcomingRow(_ row: RemindersUpcomingRow) -> some View {
        let title = row.sessionTitle
        return RemindersUpcomingRowView(
            row: row,
            showsActions: hovered == row.id || selection == row.id,
            clock: clock,
            onEdit: { edit(row) },
            onCancel: { cancel(row) },
            summary: RemindersRowAccessibility(
                identifier: "reminders-upcoming.\(title)",
                label: upcomingAccessibilityLabel(row),
                value: ReminderActions.detail(for: row.reminder, store: store).map { "reminder pending: \($0)" }
                    ?? "reminder pending",
                actions: [
                    .init(name: "Open Session") { openSession(row.sessionID) },
                    .init(name: "Edit Reminder") { edit(row) },
                    .init(name: "Cancel Reminder") { cancel(row) },
                ])
        )
        .tag(row.id)
        .contentShape(Rectangle())
        .onTapGesture { openSession(row.sessionID) }
        .onHover { hover(row.id, $0) }
        .contextMenu {
            Button("Open Session") { openSession(row.sessionID) }
            Button("Edit Reminder…") { edit(row) }
            Button("Cancel Reminder") { cancel(row) }
        }
    }

    // MARK: - Time

    /// The scheduler's clock, not `TimelineView`'s date: UI tests freeze it.
    private var clock: RemindersClock {
        let scheduler = store.reminderScheduler
        return RemindersClock(now: { scheduler.now }, calendar: { scheduler.calendar })
    }

    private func dueAccessibilityLabel(_ row: RemindersDueRow) -> String {
        let phrase = ReminderFormat.dueAtLine(row.fired.dueAt, calendar: clock.calendar())
        let base = "Reminder, \(row.text), \(row.sessionTitle), \(phrase)"
        return row.isUnread ? "\(base), unread" : base
    }

    private func upcomingAccessibilityLabel(_ row: RemindersUpcomingRow) -> String {
        guard let due = row.dueAt else { return "Reminder, \(row.text), \(row.sessionTitle)" }
        let phrase = ReminderFormat.phrase(for: due, now: clock.now(), calendar: clock.calendar())
        return "Reminder, \(row.text), \(row.sessionTitle), \(phrase)"
    }

    // MARK: - Actions (event-origin only)

    private func hover(_ id: RemindersRowID, _ inside: Bool) {
        if inside {
            hovered = id
        } else if hovered == id {
            hovered = nil
        }
    }

    /// Runs `work`, then moves the selection to the row that took the
    /// removed row's place.
    private func act(_ work: () -> Void) {
        let before = RemindersListModel.current(in: store).rowIDs
        work()
        selection = RemindersListModel.selection(selection, after: before, in: .current(in: store))
    }

    private func openSession(_ sessionID: UUID) {
        onDismiss()
        store.openReminderSession(sessionID: sessionID)
    }

    private func remindAgain(_ row: RemindersDueRow, minutes: Int) {
        act { store.remindFiredReminderAgain(id: row.fired.id, minutes: minutes) }
    }

    private func done(_ row: RemindersDueRow) {
        act { store.markFiredReminderDone(id: row.fired.id) }
    }

    private func cancel(_ row: RemindersUpcomingRow) {
        act { store.cancelReminder(forSessionID: row.sessionID) }
    }

    private func edit(_ row: RemindersUpcomingRow) {
        onDismiss()
        ReminderActions.openBarFromList(sessionID: row.sessionID, store: store)
    }

    private func newReminder() {
        onDismiss()
        guard let session = windowRuntime.selectedSession else { return }
        ReminderActions.openBar(
            for: session, in: windowRuntime,
            windowHasAttachedSheet: store.windowHasAttachedSheet(windowRuntime.id))
    }
}

/// Unobserved reads of the Reminder scheduler's clock.
private struct RemindersClock {
    let now: () -> Date
    let calendar: () -> Calendar
}

/// A row's summary (everything but its buttons) is one accessibility
/// element carrying the row's identifier, label and value. A
/// `.contain` group around the whole row exposes no value, so the
/// buttons stay outside the summary as its siblings.
private struct RemindersRowSummary<Content: View>: View {
    let content: Content
    let accessibility: RemindersRowAccessibility

    var body: some View {
        content
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(accessibility.identifier)
            .accessibilityLabel(accessibility.label)
            .accessibilityValue(accessibility.value)
            .accessibilityActions {
                ForEach(accessibility.actions, id: \.name) { action in
                    Button(action.name, action: action.perform)
                }
            }
    }
}

private struct RemindersRowAccessibility {
    struct Action {
        let name: String
        let perform: () -> Void
    }

    let identifier: String
    let label: String
    let value: String
    let actions: [Action]
}

private extension HorizontalAlignment {
    private enum RemindersRowText: AlignmentID {
        static func defaultValue(in context: ViewDimensions) -> CGFloat { context[.leading] }
    }

    static let remindersRowText = HorizontalAlignment(RemindersRowText.self)
}

private struct RemindersDueRowView: View {
    let row: RemindersDueRow
    let showsActions: Bool
    let clock: RemindersClock
    let onRemindAgain: (Int) -> Void
    let onDone: () -> Void
    let summary: RemindersRowAccessibility

    var body: some View {
        let title = row.sessionTitle
        VStack(alignment: .remindersRowText, spacing: 4) {
            RemindersRowSummary(content: summaryContent, accessibility: summary)
            if showsActions {
                HStack(spacing: 6) {
                    Button("Remind Again in 15 Minutes") { onRemindAgain(15) }
                        .disabled(!row.canRemindAgain)
                        .accessibilityIdentifier("reminders-due.again15.\(title)")
                    Button("In 1 Hour") { onRemindAgain(60) }
                        .disabled(!row.canRemindAgain)
                        .accessibilityIdentifier("reminders-due.again60.\(title)")
                    Button("Done", action: onDone)
                        .accessibilityIdentifier("reminders-due.done.\(title)")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .alignmentGuide(.remindersRowText) { $0[.leading] }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }

    private var summaryContent: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(row.isUnread ? Color.accentColor : Color.clear)
                .frame(width: 8, height: 8)
                .padding(.top, 5)
                .accessibilityHidden(true)
            Image(systemName: "alarm")
                .foregroundStyle(Color.accentColor)
                .padding(.top, 1)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(row.text)
                        .font(.callout.weight(.medium))
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    TimelineView(.everyMinute) { _ in
                        Text(ReminderFormat.firedAgo(row.fired.firedAt, now: clock.now(), calendar: clock.calendar()))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                            .monospacedDigit()
                    }
                }
                Text(verbatim: "\(row.sessionTitle) \u{00B7} \(ReminderFormat.dueAtLine(row.fired.dueAt, calendar: clock.calendar()))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .alignmentGuide(.remindersRowText) { $0[.leading] }
        }
    }
}

private struct RemindersUpcomingRowView: View {
    let row: RemindersUpcomingRow
    let showsActions: Bool
    let clock: RemindersClock
    let onEdit: () -> Void
    let onCancel: () -> Void
    let summary: RemindersRowAccessibility

    var body: some View {
        let title = row.sessionTitle
        HStack(alignment: .top, spacing: 8) {
            RemindersRowSummary(content: summaryContent, accessibility: summary)
            if showsActions {
                HStack(spacing: 4) {
                    Button(action: onEdit) {
                        Image(systemName: "pencil")
                    }
                    .help("Edit Reminder…")
                    .accessibilityLabel("Edit Reminder…")
                    .accessibilityIdentifier("reminders-upcoming.edit.\(title)")
                    Button(action: onCancel) {
                        Image(systemName: "xmark")
                    }
                    .help("Cancel Reminder")
                    .accessibilityLabel("Cancel Reminder")
                    .accessibilityIdentifier("reminders-upcoming.cancel.\(title)")
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 2)
    }

    private var summaryContent: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "clock")
                .foregroundStyle(.secondary)
                .padding(.top, 1)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(row.text)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let due = row.dueAt {
                        TimelineView(.everyMinute) { _ in
                            Text(ReminderFormat.relativeLine(due: due, now: clock.now(), calendar: clock.calendar()))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }
                TimelineView(.everyMinute) { _ in
                    Text(verbatim: line2)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
    }

    private var line2: String {
        guard let due = row.dueAt else { return row.sessionTitle }
        return "\(row.sessionTitle) \u{00B7} \(ReminderFormat.phrase(for: due, now: clock.now(), calendar: clock.calendar()))"
    }
}

private extension RemindersListKey {
    var keyEquivalent: KeyEquivalent {
        switch self {
        case .up: .upArrow
        case .down: .downArrow
        case .open: .return
        case .delete: .delete
        case .edit: "e"
        case .remindAgain: "r"
        }
    }
}
