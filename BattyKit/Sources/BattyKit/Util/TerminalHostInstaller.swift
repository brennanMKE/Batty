// TerminalHostInstaller.swift

import AppKit
import SwiftUI

/// `NSViewRepresentable` for the long-lived ``TerminalHostView`` owned by a
/// specific content window. This is Pattern 3 from
/// `nsviewrepresentable-state-persistence.md`: the host is owned by the
/// process-wide ``TerminalHostStore`` registry and the representable's
/// `makeNSView` returns that **existing** instance for the given window
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
    let windowID: WindowID

    func makeNSView(context: Context) -> TerminalHostView {
        // Return the EXISTING host for this window from the registry. Never
        // construct a new one — even if SwiftUI tears down and rebuilds this
        // representable, the host (and all its terminal subviews) must survive
        // in TerminalHostStore.shared. Pattern 3: external singleton owns the
        // NSView; the representable is a thin shim.
        TerminalHostStore.shared.hostView(forWindowID: windowID)
    }

    func updateNSView(_ nsView: TerminalHostView, context: Context) {
        // No-op. Geometry is pushed into the host via
        // TerminalHostStore.updatePlacements(_:forWindowID:), which is driven
        // by TerminalPlacementPreferenceKey changes — not by SwiftUI
        // representable updates.
    }

    static func dismantleNSView(_ nsView: TerminalHostView, coordinator: ()) {
        // Intentionally empty. The host and its subviews are owned by
        // TerminalHostStore.shared and must survive representable tear-down.
        // Releasing here would destroy every live PTY in the window on any
        // view-hierarchy churn.
    }
}
