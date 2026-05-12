// ShortcutsSettingsView.swift

import SwiftUI

/// Shortcuts pane: one row per `ShortcutAction`, each with a recorder and a
/// per-row reset button. Surfaces collisions and reserved-shortcut conflicts
/// inline beneath the offending row.
public struct ShortcutsSettingsView: View {
    @State private var store = ShortcutsStore.shared

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Form {
                ForEach(ShortcutAction.allCases) { action in
                    ShortcutRow(action: action, store: store)
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Reset All to Defaults") {
                    store.resetAllToDefaults()
                }
            }
            .padding(.horizontal)
            .padding(.bottom)
        }
    }
}
