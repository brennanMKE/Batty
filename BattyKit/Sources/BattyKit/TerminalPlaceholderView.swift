// TerminalPlaceholderView.swift

import AppKit
import Foundation
import SwiftUI

/// SwiftUI view that occupies the spot in the pane where the terminal
/// should appear. It does not host the terminal NSView — that lives in
/// the long-lived ``TerminalHostView`` owned by ``TerminalHostStore``.
/// This placeholder is purely a geometry probe: it reports its frame in
/// the ``TerminalHostInstaller.coordinateSpaceName`` coordinate space
/// (which is anchored to the host installer's container) so the host can
/// position the corresponding terminal view to overlay it.
///
/// Why a named coordinate space and not `.global`? The host is inserted
/// into the SwiftUI tree as a sibling of the session chrome via
/// ``TerminalHostInstaller`` (see `SessionDetailView`). The host's
/// internal coordinate space (`host.bounds`) is local to the host
/// `NSView`. By emitting frames relative to a named space at the same
/// SwiftUI position as the host installer, we get values that go
/// directly into `subview.frame` on the host without further conversion.
struct TerminalPlaceholderView: View {
    let tab: TabRuntime
    let isVisible: Bool
    let paneID: UUID
    let isPaneFocused: Bool

    var body: some View {
        GeometryReader { proxy in
            // Touch the terminal view eagerly so libghostty starts the
            // PTY the moment the first placeholder appears. This is
            // idempotent: subsequent calls return the same view.
            let _ = TerminalHostStore.shared.terminalView(for: tab)
            let placement = TerminalHostStore.Placement(
                frame: proxy.frame(in: .named(TerminalHostInstaller.coordinateSpaceName)),
                isVisible: isVisible
            )
            Color.clear
                .preference(
                    key: TerminalPlacementPreferenceKey.self,
                    value: [tab.id: placement]
                )
                .accessibilityIdentifier("pane-terminal.\(paneID.uuidString)")
                .accessibilityValue(isPaneFocused ? "focused" : "unfocused")
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

extension TerminalHostInstaller {
    /// Name of the SwiftUI coordinate space that anchors the host. Both
    /// the host installer's parent and ``TerminalPlaceholderView`` use
    /// this name — the placeholder reports its frame in this space and
    /// the host's terminal subviews are placed at that frame directly.
    static let coordinateSpaceName: String = "terminal-host"
}
