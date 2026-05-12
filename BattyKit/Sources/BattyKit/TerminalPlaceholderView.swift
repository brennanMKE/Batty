// TerminalPlaceholderView.swift

import AppKit
import Foundation
import SwiftUI

/// SwiftUI view that occupies the spot in the pane where the terminal
/// should appear. It does not host the terminal NSView — that lives in
/// the long-lived ``TerminalHostView`` owned by ``TerminalHostStore``.
/// This placeholder is purely a geometry probe: it reports its
/// window-coordinate frame upward through ``TerminalPlacementPreferenceKey``
/// so the host can position the corresponding terminal view to overlay it.
///
/// Why a `GeometryReader` and not a plain `Color.clear.background`? We
/// need the frame in *window* coordinates, not pane-local — the host is
/// parented to the window's `contentView`, and its subviews are placed
/// with frames relative to that. SwiftUI's `frame(in: .global)` returns
/// the value we need. The placeholder also emits a release request via
/// `onDisappear` so the host can release a terminal view when its tab
/// is no longer mounted.
struct TerminalPlaceholderView: View {
    let tab: TabRuntime
    let isVisible: Bool

    var body: some View {
        GeometryReader { proxy in
            // Touch the terminal view eagerly so libghostty starts the
            // PTY the moment the first placeholder appears. This is
            // idempotent: subsequent calls return the same view.
            let _ = TerminalHostStore.shared.terminalView(for: tab)
            let placement = TerminalHostStore.Placement(
                frame: proxy.frame(in: .global),
                isVisible: isVisible
            )
            Color.clear
                .preference(
                    key: TerminalPlacementPreferenceKey.self,
                    value: [tab.id: placement]
                )
        }
    }
}

/// Aggregates terminal placements from every mounted ``TerminalPlaceholderView``.
/// `SessionDetailView` reads the merged map and forwards it to the host
/// store on every change.
struct TerminalPlacementPreferenceKey: PreferenceKey {
    static let defaultValue: [UUID: TerminalHostStore.Placement] = [:]

    static func reduce(
        value: inout [UUID: TerminalHostStore.Placement],
        nextValue: () -> [UUID: TerminalHostStore.Placement]
    ) {
        let next = nextValue()
        for (id, placement) in next {
            // If the same tab id appears twice (e.g. tab visible in
            // multiple panes — impossible by construction but defensive),
            // the visible one wins; otherwise the latter wins.
            if let existing = value[id], existing.isVisible, !placement.isVisible {
                continue
            }
            value[id] = placement
        }
    }
}
