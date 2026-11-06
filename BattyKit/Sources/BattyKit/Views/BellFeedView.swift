// BellFeedView.swift

import SwiftUI

public struct BellFeedView: View {
    let store: AppStateStore
    let onJump: ((BellFeedEntry) -> Void)?
    let onDismiss: (() -> Void)?

    @State private var selectedEntryID: UUID?
    @State private var suggestion: SuggestionTarget?
    @FocusState private var focusedRegion: FocusRegion?

    public init(
        store: AppStateStore,
        onJump: ((BellFeedEntry) -> Void)? = nil,
        onDismiss: (() -> Void)? = nil
    ) {
        self.store = store
        self.onJump = onJump
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let target = suggestion,
               let entry = store.bellFeed.entries.first(where: { $0.id == target.id }) {
                let id = target.id
                BellSuggestionEditor(
                    focus: $focusedRegion,
                    initialText: entry.displayText ?? "",
                    onSave: { text in
                        store.suggestBellText(id: id, text: text, snapshot: target.snapshot)
                        suggestion = nil
                    },
                    onCancel: { suggestion = nil }
                )
                .id(id)
            } else if store.bellFeed.entries.isEmpty {
                ContentUnavailableView(
                    "No bell events",
                    systemImage: "bell.slash",
                    description: Text("Bell events from your terminals show up here.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selectedEntryID) {
                    ForEach(store.bellFeed.entries) { entry in
                        BellFeedRow(
                            entry: entry,
                            path: pathLabel(for: entry)
                        )
                        .tag(entry.id)
                        .contentShape(Rectangle())
                        .onTapGesture { handleJump(to: entry) }
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("bell-feed-entry.\(entry.id.uuidString)")
                        .modifier(ReminderEntryAccessibility(isReminder: entry.kind == .reminder))
                        .contextMenu { ratingMenu(for: entry) }
                    }
                }
                .accessibilityIdentifier("bell-feed.list")
                .listStyle(.plain)
                .onKeyPress(.return) {
                    guard let id = selectedEntryID,
                          let entry = store.bellFeed.entries.first(where: { $0.id == id })
                    else { return .ignored }
                    handleJump(to: entry)
                    return .handled
                }
                .onKeyPress(.escape) {
                    onDismiss?()
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    moveSelection(by: -1)
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    moveSelection(by: 1)
                    return .handled
                }
            }
        }
        .frame(width: 360, height: 420)
        .onAppear {
            if selectedEntryID == nil {
                selectedEntryID = store.bellFeed.entries.first?.id
            }
        }
    }

    @ViewBuilder
    private func ratingMenu(for entry: BellFeedEntry) -> some View {
        let availability = store.bellRatingAvailability(for: entry)
        if availability != .hidden {
            let enabled = availability == .available
            let verdict = store.bellFeed.ratingVerdicts[entry.id]
            Toggle("Good Summary", isOn: Binding(
                get: { verdict == .good },
                set: { _ in store.rateBellEntry(id: entry.id, verdict: .good) }
            ))
            .disabled(!enabled)
            .accessibilityIdentifier(verdict == .good ? "bell-feed.rating.good.selected" : "bell-feed.rating.good")
            Toggle("Bad Summary", isOn: Binding(
                get: { verdict == .bad },
                set: { _ in store.rateBellEntry(id: entry.id, verdict: .bad) }
            ))
            .disabled(!enabled)
            .accessibilityIdentifier(verdict == .bad ? "bell-feed.rating.bad.selected" : "bell-feed.rating.bad")
            Button("Suggest Better Text…") {
                suggestion = store.bellRatingSnapshot(forEntryID: entry.id)
                    .map { SuggestionTarget(id: entry.id, snapshot: $0) }
                if suggestion != nil { focusedRegion = .suggestionField }
            }
                .disabled(!enabled)
                .accessibilityIdentifier("bell-feed.rating.suggest")
            Button("Clear Rating") { store.rateBellEntry(id: entry.id, verdict: .cleared) }
                .disabled(!enabled || verdict == nil)
                .accessibilityIdentifier("bell-feed.rating.clear")
            if !enabled {
                Text("Not captured: this entry arrived before capture was turned on or the capture log was cleared.")
            }
        }
    }

    private func moveSelection(by delta: Int) {
        let entries = store.bellFeed.entries
        guard !entries.isEmpty else { return }
        let currentIndex = entries.firstIndex(where: { $0.id == selectedEntryID }) ?? -1
        let nextIndex = (currentIndex + delta + entries.count) % entries.count
        selectedEntryID = entries[nextIndex].id
    }

    private var header: some View {
        HStack {
            Text("Bell Feed")
                .font(.headline)
            Spacer()
            if !store.bellFeed.entries.isEmpty {
                Button("Clear All") {
                    store.markAllBellsSeen()
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func handleJump(to entry: BellFeedEntry) {
        store.markBellSeen(id: entry.id)
        onJump?(entry)
    }

    private func pathLabel(for entry: BellFeedEntry) -> String {
        if entry.sessionID == BellFeedEntry.systemID {
            return String(localized: "Batty")
        }
        if entry.kind == .reminder {
            return store.session(id: entry.sessionID)?.title ?? String(localized: "(closed)")
        }
        // Search all windows' sessions to find the owning session (#0239:
        // entries can belong to any window's sessions, not just windows[0]).
        let allSessions = store.windows.flatMap { $0.sessions }
        guard let session = allSessions.first(where: { $0.id == entry.sessionID }),
              let pane = session.tree.allPanes.first(where: { $0.id == entry.paneID }),
              let tab = pane.tabs.first(where: { $0.id == entry.tabID })
        else {
            return String(localized: "(closed)")
        }
        let paneIndex = (session.tree.allPanes.firstIndex(where: { $0.id == pane.id }) ?? 0) + 1
        let tabIndex = (pane.tabs.firstIndex(where: { $0.id == tab.id }) ?? 0) + 1
        let tabLabel = AppStateStore.tabLabel(for: tab, tabIndex: tabIndex)
        return BellFeedEntry.pathLabel(sessionTitle: session.title, paneIndex: paneIndex, tabLabel: tabLabel)
    }
}

private struct BellFeedRow: View {
    let entry: BellFeedEntry
    let path: String

    var body: some View {
        if entry.kind == .reminder {
            reminderBody
        } else {
            bellBody
        }
    }

    /// A Reminder reads differently from a bell: an alarm icon in the accent
    /// color, "Reminder" with the Session's title, the note (or a prompt to
    /// come back) and how long ago it was set, or when it was due if it came
    /// due long before it was delivered, such as across a sleep.
    private var reminderBody: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(entry.seen ? Color.clear : Color.accentColor)
                .frame(width: 8, height: 8)
                .padding(.top, 5)
            Image(systemName: "alarm")
                .foregroundStyle(Color.accentColor)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Reminder")
                        .font(.callout.weight(.semibold))
                    Text(path)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .accessibilityIdentifier("bell-feed-path.\(entry.id.uuidString)")
                    Spacer()
                    Text(entry.timestamp, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help(entry.timestamp.formatted(date: .abbreviated, time: .standard))
                }
                Text(entry.message ?? String(localized: "Time to come back to \(path)"))
                    .font(.caption)
                    .lineLimit(3)
                    .accessibilityIdentifier("bell-feed-message.\(entry.id.uuidString)")
                if let line = secondaryLine {
                    Text(line)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("bell-feed-reminder-detail.\(entry.id.uuidString)")
                }
            }
        }
        .padding(.vertical, 2)
    }

    private static let lateAfter: TimeInterval = 60

    private var secondaryLine: String? {
        if let due = entry.reminderDueAt, entry.timestamp.timeIntervalSince(due) > Self.lateAfter {
            return String(localized: "Due \(ReminderFormat.time(due))")
        }
        guard let setAt = entry.reminderSetAt else { return nil }
        let ago = setAt.formatted(.relative(presentation: .named, unitsStyle: .wide))
        return String(localized: "Set \(ago)")
    }

    private var bellBody: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(entry.seen ? Color.clear : Color.accentColor)
                .frame(width: 8, height: 8)
                .padding(.top, 5)
                .accessibilityElement()
                .accessibilityLabel(entry.seen ? "Seen" : "Unseen")
                .accessibilityIdentifier("bell-feed-\(entry.seen ? "seen" : "unseen").\(entry.id.uuidString)")
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(path)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .accessibilityIdentifier("bell-feed-path.\(entry.id.uuidString)")
                    if entry.repeatCount > 1 {
                        Text(verbatim: "×\(entry.repeatCount)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .help("Repeated \(entry.repeatCount) times since the last time this was seen")
                    }
                    Spacer()
                    Text(entry.timestamp, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help(entry.timestamp.formatted(date: .abbreviated, time: .standard))
                }
                if let display = entry.displayText {
                    Text(display)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .accessibilityIdentifier("bell-feed-message.\(entry.id.uuidString)")
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// Adds the `reminder` value to a Reminder row only, so a bell row's
/// accessibility value is exactly what it was before Reminders existed.
private struct ReminderEntryAccessibility: ViewModifier {
    let isReminder: Bool

    func body(content: Content) -> some View {
        if isReminder {
            content.accessibilityValue("reminder")
        } else {
            content
        }
    }
}

private enum FocusRegion: Hashable {
    case suggestionField
}

private struct SuggestionTarget {
    let id: UUID
    let snapshot: BellRatingSnapshot
}

private struct BellSuggestionEditor: View {
    let focus: FocusState<FocusRegion?>.Binding
    let onSave: (String) -> Void
    let onCancel: () -> Void

    @State private var draft: String

    init(focus: FocusState<FocusRegion?>.Binding, initialText: String, onSave: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.focus = focus
        _draft = State(initialValue: initialText)
        self.onSave = onSave
        self.onCancel = onCancel
    }

    private var canSave: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Suggest Better Text")
                .font(.headline)
            Text("Return saves.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Better text", text: $draft, axis: .vertical)
                .lineLimit(4...10)
                .textFieldStyle(.roundedBorder)
                .focused(focus, equals: .suggestionField)
                .onKeyPress(.escape) {
                    onCancel()
                    return .handled
                }
                .onKeyPress(keys: [.return]) { press in
                    guard press.modifiers.isEmpty else { return .ignored }
                    guard canSave else { return .handled }
                    onSave(draft)
                    return .handled
                }
                .accessibilityIdentifier("bell-feed.suggest.field")
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("bell-feed.suggest.cancel")
                Button("Save") { onSave(draft) }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!canSave)
                    .accessibilityIdentifier("bell-feed.suggest.save")
            }
        }
        .padding(12)
        .onKeyPress(.escape) {
            onCancel()
            return .handled
        }
    }
}
