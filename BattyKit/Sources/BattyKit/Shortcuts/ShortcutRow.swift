// ShortcutRow.swift

import SwiftUI

/// One Form row: name, recorder, per-row reset, and an inline warning row when
/// the current binding collides with another action or hits a reserved combo.
struct ShortcutRow: View {
    let action: ShortcutAction
    let store: ShortcutsStore

    var body: some View {
        let current = store.binding(for: action)
        let collisions = store.collisions(current, excluding: action)
        let reserved = ShortcutsStore.isReserved(current)

        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(verbatim: action.displayName)
                Spacer()
                KeyboardShortcutRecorder(binding: bindingProxy)
                    .frame(width: 130, height: KeyboardShortcutRecorder.preferredHeight)

                Button("Reset") {
                    store.resetToDefault(action)
                }
                .controlSize(.small)
                .disabled(current == action.defaultBinding)
            }

            if reserved {
                warning(String(localized: "Reserved by macOS — choose a different shortcut."))
            } else if let other = collisions.first {
                warning(String(localized: "Used by \(other.displayName)"))
            }
        }
    }

    /// Bridges `KeyboardShortcutRecorder`'s `@Binding<ShortcutBinding>` to the
    /// store. Reserved combos are saved anyway so the warning row appears;
    /// the user can hit Reset or pick a non-reserved combo (v1 trade-off).
    private var bindingProxy: Binding<ShortcutBinding> {
        Binding(
            get: { store.binding(for: action) },
            set: { newValue in
                store.setBinding(newValue, for: action)
            }
        )
    }

    private func warning(_ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(verbatim: text)
        }
        .font(.caption)
        .foregroundStyle(Color.orange)
    }
}
