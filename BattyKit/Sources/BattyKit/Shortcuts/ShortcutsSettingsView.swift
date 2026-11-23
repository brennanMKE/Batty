// ShortcutsSettingsView.swift

import BattyXPCCore
import SwiftUI

/// Shortcuts pane: one row per `ShortcutAction`, each with a recorder and a
/// per-row reset button. Surfaces collisions and reserved-shortcut conflicts
/// inline beneath the offending row.
public struct ShortcutsSettingsView: View {
    private let store = ShortcutsStore.shared
    private let flags: FeatureFlags

    public init(flags: FeatureFlags) {
        self.flags = flags
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Form {
                ForEach(ShortcutAction.allCases.filter { $0.isAvailable(flags) }) { action in
                    ShortcutRow(action: action, store: store, flags: flags)
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
