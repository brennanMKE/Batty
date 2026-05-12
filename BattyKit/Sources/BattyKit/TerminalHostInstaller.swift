// TerminalHostInstaller.swift

import AppKit
import SwiftUI

/// `NSViewRepresentable` for the long-lived ``TerminalHostView``. This
/// is Pattern 3 from `nsviewrepresentable-state-persistence.md`: the
/// host is owned by an external singleton (``TerminalHostStore``) and
/// the representable's `makeNSView` returns that **existing** instance
/// rather than constructing a new one. SwiftUI is free to tear down and
/// rebuild this representable; the host (and every terminal subview it
/// contains) survives in the store.
///
/// Why a representable instead of attaching the host to `window.contentView`
/// from a side channel: on modern macOS, `window.contentView` is an
/// `NSHostingController.view`. AppKit logs a "broken view hierarchy"
/// warning when a foreign `NSView` is added as a subview of an
/// `NSHostingController.view`, and the practical effect is that the
/// foreign view doesn't paint reliably. The supported approach is to
/// insert the foreign view *into the SwiftUI tree* via an
/// `NSViewRepresentable` — which is what this type does.
struct TerminalHostInstaller: NSViewRepresentable {
    func makeNSView(context: Context) -> TerminalHostView {
        // Return the EXISTING host from the singleton. Never construct a
        // new one — even if SwiftUI tears down and rebuilds this
        // representable, the host (and all its terminal subviews) must
        // survive in TerminalHostStore.shared.
        TerminalHostStore.shared.hostView
    }

    func updateNSView(_ nsView: TerminalHostView, context: Context) {
        // No-op. Geometry is pushed into the host via
        // TerminalHostStore.updatePlacements(_:), which is driven by
        // TerminalPlacementPreferenceKey changes — not by SwiftUI
        // representable updates.
    }

    static func dismantleNSView(_ nsView: TerminalHostView, coordinator: ()) {
        // Intentionally empty. The host and its subviews are owned by
        // TerminalHostStore.shared and must survive representable
        // tear-down. Releasing here would destroy every live PTY in the
        // app on any view-hierarchy churn.
    }
}
