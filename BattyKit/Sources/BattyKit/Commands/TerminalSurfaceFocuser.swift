// TerminalSurfaceFocuser.swift

import AppKit
import GhosttyTerminal
import OSLog

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "TerminalSurfaceFocuser")

/// Routes AppKit first-responder status to the `AppTerminalView` whose
/// libghostty delegate is a given `TerminalViewState`. SwiftUI's
/// `NSViewRepresentable` bridge does not auto-promote the wrapped NSView
/// to first responder when the window first becomes key, so we walk the
/// view tree ourselves on launch and on every Session/Pane/Tab focus
/// change.
enum TerminalSurfaceFocuser {
    /// Make the `AppTerminalView` whose delegate is `terminal` the window's
    /// first responder. Searches every window's view hierarchy because the
    /// active window may not be `keyWindow` at the moment focus is requested
    /// (e.g. during cold launch the window may not have become key yet).
    static func focus(terminal: TerminalViewState) {
        for window in NSApp.windows {
            guard let contentView = window.contentView else { continue }
            if let match = findTerminalView(in: contentView, matching: terminal) {
                if window.firstResponder === match { return }
                window.makeFirstResponder(match)
                return
            }
        }
        logger.debug("focus skipped: no AppTerminalView matched the requested terminal state")
    }

    /// Retry-after-delay variant. The first attempt happens immediately; if no
    /// match is found (the NSView may not yet be in the hierarchy for a brand
    /// new surface), retry once after a short delay.
    static func focusWhenReady(terminal: TerminalViewState) {
        focus(terminal: terminal)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            focus(terminal: terminal)
        }
    }

    private static func findTerminalView(
        in view: NSView,
        matching terminal: TerminalViewState
    ) -> AppTerminalView? {
        if let candidate = view as? AppTerminalView, candidate.delegate === terminal {
            return candidate
        }
        for subview in view.subviews {
            if let match = findTerminalView(in: subview, matching: terminal) {
                return match
            }
        }
        return nil
    }
}
