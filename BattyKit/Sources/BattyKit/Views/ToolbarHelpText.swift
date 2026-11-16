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
