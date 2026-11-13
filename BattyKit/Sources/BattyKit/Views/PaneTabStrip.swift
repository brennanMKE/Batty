// PaneTabStrip.swift

import SlidingTabs
import SwiftUI

/// Owns the tab strip's width so a resize re-evaluates only this view, not
/// the whole `PaneView`.
struct PaneTabStrip<Chip: View>: View {
    @Bindable var pane: PaneRuntime
    let activeID: Binding<UUID?>
    let onAdd: () -> Void
    @ViewBuilder let chip: (TabRuntime, Bool, CGFloat) -> Chip

    @State private var stripWidth: CGFloat = 0

    /// SlidingTabBar's own per-bar overhead: 2×12 h-padding + 22 "+" button
    /// + the button's 12 trailing padding = 58.
    private static var barChromeWidth: CGFloat { 58 }
    /// Absolute clamps so chips don't disappear in tiny panes or grow
    /// absurdly wide in huge ones.
    private static var chipMinWidth: CGFloat { 60 }
    private static var chipMaxWidthCap: CGFloat { 220 }

    /// The strip is measured after the drag handle and eye button take their
    /// space, so their reservations fall out of `stripWidth`.
    static func chipWidth(stripWidth: CGFloat, tabCount: Int) -> CGFloat {
        let available = max(0, stripWidth - barChromeWidth)
        let perChip = (available / CGFloat(max(1, tabCount))) - 6  // SlidingTabBar's default spacing
        return min(chipMaxWidthCap, max(chipMinWidth, perChip))
    }

    var body: some View {
        let chipWidth = Self.chipWidth(stripWidth: stripWidth, tabCount: pane.tabs.count)
        // The strip is laid out inside an overlay of a flexible placeholder
        // so its (fixed-size) reported width cannot push the trailing
        // controls out of the Pane, and chip widths cannot feed back into
        // `stripWidth`, so this geometry write converges.
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: PaneView.nonTerminalHeaderHeight)
            .overlay(alignment: .leading) {
                SlidingTabBar(
                    items: $pane.tabs,
                    activeID: activeID,
                    onReorderCommit: nil,
                    onAdd: onAdd
                ) { tab, isActive in
                    chip(tab, isActive, chipWidth)
                }
                // .contain marks the tab bar as a container so children stay
                // as discrete accessibility elements with their own ids. Without
                // this, SwiftUI on macOS folds the bar into a leaf and the
                // identifier propagates down to every child Button — chip,
                // close, and "+" all end up with identifier "tab-bar.<uuid>",
                // and `tab-chip.<title>` becomes unfindable.
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("tab-bar.\(pane.id.uuidString)")
            }
            .clipped()
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { stripWidth = $0 }
    }
}
