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
    ///
    /// Returns `true` when the view was found and was either already focused
    /// or successfully promoted. Returns `false` when the view could not be
    /// located (it has not yet been added to a window) or is still hidden
    /// (AppKit refuses to deliver key events to hidden views, so we treat a
    /// hidden match as "not ready" and let the caller retry).
    @discardableResult
    static func focus(terminal: TerminalViewState) -> Bool {
        for window in NSApp.windows {
            guard let contentView = window.contentView else { continue }
            guard let match = findTerminalView(in: contentView, matching: terminal) else { continue }
            // A hidden view can become first responder, but key events are
            // not dispatched to it and the libghostty surface won't see
            // the focus until the host's next placement pass unhides it.
            // Treat this as "not ready" so the caller retries.
            if match.isHidden { return false }
            if window.firstResponder === match { return true }
            window.makeFirstResponder(match)
            return true
        }
        return false
    }

    /// Retry variant. The first attempt happens immediately; subsequent
    /// attempts are scheduled at a back-off until the view is locatable
    /// and visible. Bounded so a closed/replaced surface doesn't leak
    /// retry tasks.
    ///
    /// Why multiple retries: a newly inserted session's pane and its
    /// terminal `AppTerminalView` traverse three independent runloop turns
    /// before keystrokes can land: (1) SwiftUI mounts the placeholder and
    /// `TerminalHostStore.terminalView(for:)` creates and attaches the
    /// `AppTerminalView` (`isHidden = true`); (2) the placeholder reports
    /// its frame via `PreferenceKey`; (3) `TerminalHostStore.updatePlacements`
    /// unhides the view. A single 50ms retry can race past step 3 under
    /// load; a staggered schedule does not.
    static func focusWhenReady(terminal: TerminalViewState) {
        if focus(terminal: terminal) { return }
        Task { @MainActor [weak terminal] in
            let delays: [Duration] = [
                .milliseconds(16),
                .milliseconds(50),
                .milliseconds(150),
                .milliseconds(400),
            ]
            for delay in delays {
                try? await Task.sleep(for: delay)
                guard let terminal else { return }
                if focus(terminal: terminal) { return }
            }
            logger.debug("focus skipped: no visible AppTerminalView matched the requested terminal state after \(delays.count, privacy: .public) retries")
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
