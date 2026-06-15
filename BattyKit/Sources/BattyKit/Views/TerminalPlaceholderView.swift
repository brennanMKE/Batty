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

    @Environment(\.windowID) private var windowID

    @State private var lastFrame: CGRect = .zero

    var body: some View {
        // Touch the terminal view eagerly so libghostty starts the PTY
        // the moment the first placeholder appears. Idempotent — the
        // store returns the existing view on every call after the first.
        //
        // `windowID` is set in the environment by `SessionDetailView`
        // (via `.environment(\.windowID, store.windows[0].id)`), so it is
        // always non-nil here. The force-unwrap is deliberately a crash:
        // a nil windowID means the view is mounted outside its intended
        // host hierarchy, and crashing early surfaces that misconfiguration.
        let windowID = windowID!
        let _ = TerminalHostStore.shared.terminalView(for: tab, windowID: windowID)
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
            .accessibilityElement()
            .accessibilityLabel(isPaneFocused ? "focused" : "unfocused")
            .accessibilityIdentifier("pane-terminal.\(paneID.uuidString)")
    }
}

extension TerminalHostInstaller {
    /// Name of the SwiftUI coordinate space that anchors the host. Both
    /// the host installer's parent and ``TerminalPlaceholderView`` use
    /// this name — the placeholder reports its frame in this space and
    /// the host's terminal subviews are placed at that frame directly.
    static let coordinateSpaceName: String = "terminal-host"
}
