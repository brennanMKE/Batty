// TerminalClickFocusMonitor.swift

import AppKit
import GhosttyTerminal
import OSLog

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "TerminalClickFocusMonitor")

/// Promotes a clicked `AppTerminalView` to its window's first responder
/// before the click reaches it.
///
/// libghostty-spm's `AppTerminalView.mouseDown(with:)` sends the mouse
/// position and button press to its surface but does not call
/// `window.makeFirstResponder(self)`. AppKit does not auto-promote a
/// clicked view to first responder — that is the view's responsibility —
/// so clicking on a sibling pane's terminal forwards the click to that
/// surface while keystrokes continue to flow to the previously focused
/// terminal. This monitor closes that gap by walking the hit-tested view
/// from a local `NSEvent` monitor and promoting the matching terminal
/// when a mouse button goes down.
///
/// The model-level focus follow-up (`tree.focusedPaneID`, the focus-border
/// overlay, etc.) happens here too, synchronously, via
/// `AppStateStore.focusPane(containingTabID:)`. It must NOT be inferred
/// from the terminal's `isFocused` flips downstream: libghostty flips
/// `isFocused` on existing surfaces when a new surface is created (observed
/// in #0230's trace during Cmd-D splits), so an isFocused-driven model
/// write cannot distinguish a real click from surface churn — that
/// ambiguity was the feedback-loop edge behind #0229. This monitor is the
/// single declared writer for the AppKit-initiated focus direction; the
/// model-initiated direction lives in `TerminalSurfaceFocuser`.
@MainActor
public enum TerminalClickFocusMonitor {
    private static var monitor: Any?

    /// Install the local `NSEvent` monitor. Idempotent: a second call is
    /// a no-op. Lives for the lifetime of the app — there is no
    /// `stop()` because the monitor and the app share a lifetime.
    public static func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown]
        ) { event in
            promoteFirstResponderIfNeeded(for: event)
            return event
        }
    }

    private static func promoteFirstResponderIfNeeded(for event: NSEvent) {
        guard let window = event.window else { return }
        // `NSWindow.contentView?.superview` is the window's frame view,
        // whose coordinate space matches `event.locationInWindow`. Calling
        // `hitTest` on that root view is the canonical pattern for
        // resolving a click point to the deepest matching view, mirroring
        // what `NSWindow.sendEvent` does before dispatching the mouse-down.
        guard let rootView = window.contentView?.superview ?? window.contentView else { return }
        guard let hit = rootView.hitTest(event.locationInWindow) else { return }
        guard let terminal = appTerminalAncestor(of: hit) else { return }
        if window.firstResponder !== terminal {
            window.makeFirstResponder(terminal)
        }
        // Model follow-up even when the terminal was already first
        // responder — the model can lag AppKit (e.g. focus moved by a
        // means the model never saw), and a click is an unambiguous
        // statement of which pane the user wants selected.
        guard let tabID = TerminalHostStore.shared.tabID(for: terminal) else { return }
        logger.debug("click-focus: tab=\(tabID, privacy: .public)")
        AppStateStore.shared.focusPane(containingTabID: tabID)
    }

    private static func appTerminalAncestor(of view: NSView) -> AppTerminalView? {
        var current: NSView? = view
        while let v = current {
            if let terminal = v as? AppTerminalView { return terminal }
            current = v.superview
        }
        return nil
    }
}
