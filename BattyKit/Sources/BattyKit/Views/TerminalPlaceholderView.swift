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

    @State private var lastFrame: CGRect = .zero

    var body: some View {
        // Touch the terminal view eagerly so libghostty starts the PTY
        // the moment the first placeholder appears. Idempotent.
        let _ = TerminalHostStore.shared.terminalView(for: tab)
        Color.clear
            .onGeometryChange(
                for: CGRect.self,
                of: { $0.frame(in: .named(TerminalHostInstaller.coordinateSpaceName)) }
            ) { frame in
                lastFrame = frame
                TerminalHostStore.shared.setPlacement(
                    TerminalHostStore.Placement(frame: frame, isVisible: isVisible),
                    forTabID: tab.id
                )
            }
            .onChange(of: isVisible) { _, visible in
                TerminalHostStore.shared.setPlacement(
                    TerminalHostStore.Placement(frame: lastFrame, isVisible: visible),
                    forTabID: tab.id
                )
            }
            .accessibilityIdentifier("pane-terminal.\(paneID.uuidString)")
            .accessibilityValue(isPaneFocused ? "focused" : "unfocused")
    }
}

extension TerminalHostInstaller {
    /// Name of the SwiftUI coordinate space that anchors the host. Both
    /// the host installer's parent and ``TerminalPlaceholderView`` use
    /// this name — the placeholder reports its frame in this space and
    /// the host's terminal subviews are placed at that frame directly.
    static let coordinateSpaceName: String = "terminal-host"
}
