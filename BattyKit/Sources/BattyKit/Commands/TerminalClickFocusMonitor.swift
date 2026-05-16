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
/// overlay, etc.) is driven by the existing `PaneView.onChange(of:
/// tab.terminal.isFocused)` hook: `becomeFirstResponder` calls
/// `core.setFocus(true)` which fans out through the focus delegate to
/// the view state's `isFocused` flag.
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
        if window.firstResponder === terminal { return }
        window.makeFirstResponder(terminal)
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
