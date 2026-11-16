// RemindersToolbarButton.swift

import SwiftUI

/// The only toolbar reader of fired and pending Reminder state, so a
/// Reminder change re-renders this button rather than `SessionDetailView.body`.
struct RemindersToolbarButton: View {
    let store: AppStateStore
    let windowRuntime: WindowRuntime
    @Binding var isShown: Bool

    var body: some View {
        let list = RemindersListModel.current(in: store)
        Button {
            isShown.toggle()
        } label: {
            Label("Reminders", systemImage: list.glyph.systemImage)
                .symbolRenderingMode(.hierarchical)
                .modifier(AccentWhen(enabled: list.glyph.usesAccent))
        }
        .help(ToolbarHelpText.reminders(
            ShortcutsStore.shared, list: list,
            now: store.reminderScheduler.now, calendar: store.reminderScheduler.calendar))
        .accessibilityIdentifier("toolbar.reminders")
        .accessibilityLabel("Reminders")
        .accessibilityValue(list.accessibilityValue)
        .popover(isPresented: $isShown, arrowEdge: .top) {
            RemindersView(store: store, windowRuntime: windowRuntime, onDismiss: { isShown = false })
        }
    }
}

/// Leaves the toolbar's own tint alone unless `enabled`.
private struct AccentWhen: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.foregroundStyle(Color.accentColor)
        } else {
            content
        }
    }
}
