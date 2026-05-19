// TerminalSurfaceFocuser.swift

import AppKit
import GhosttyTerminal
import OSLog

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "TerminalSurfaceFocuser")

/// Routes AppKit first-responder status to a tab's `AppTerminalView`.
/// SwiftUI's `NSViewRepresentable` bridge does not auto-promote the
/// wrapped NSView to first responder when the window first becomes key,
/// so we promote it ourselves on launch and on every Session/Pane/Tab
/// focus change.
///
/// Tab-keyed by design. The previous incarnation walked the window's view
/// tree looking for an `AppTerminalView` whose `delegate === terminal`
/// (a `TerminalViewState`). After `#0125` introduced ``TerminalDelegateProxy``
/// as the installed delegate, that identity comparison silently stopped
/// matching for every tab in the app — every `focus` call returned false,
/// the back-off ladder exhausted itself with no effect, and only the
/// click-monitor path (which does its own hit-test instead of a delegate
/// lookup) kept working. The new lookup goes straight through
/// ``TerminalHostStore`` / ``TabRuntime.terminalNSView`` so there is no
/// delegate-identity step to fall out of sync again.
enum TerminalSurfaceFocuser {
    /// Make `tab`'s `AppTerminalView` the first responder of whatever
    /// window currently hosts it.
    ///
    /// Returns `true` when the view exists, is attached to a window, is
    /// visible, and is either already first responder or was successfully
    /// promoted. Returns `false` when:
    ///   * the placeholder has not mounted yet, so no `AppTerminalView`
    ///     has been created (`tab.terminalNSView == nil`),
    ///   * the view is not yet attached to a window,
    ///   * the view is still hidden (AppKit refuses to deliver key events
    ///     to a hidden view, so a `makeFirstResponder` call on it succeeds
    ///     at the responder-chain level but never actually receives key
    ///     events — treat hidden as "not ready" so the caller retries).
    @discardableResult
    static func focus(tab: TabRuntime) -> Bool {
        guard let view = tab.terminalNSView else { return false }
        guard let window = view.window else { return false }
        if view.isHidden { return false }
        if window.firstResponder === view { return true }
        window.makeFirstResponder(view)
        return true
    }

    /// Retry variant. The first attempt happens immediately; subsequent
    /// attempts are scheduled at a back-off until the view is locatable
    /// and visible. Bounded so a closed/replaced tab does not leak retry
    /// tasks.
    ///
    /// Why multiple retries: a newly inserted session's pane and its
    /// terminal `AppTerminalView` traverse three independent runloop turns
    /// before keystrokes can land: (1) SwiftUI mounts the placeholder and
    /// `TerminalHostStore.terminalView(for:)` creates and attaches the
    /// `AppTerminalView` (`isHidden = true`); (2) the placeholder reports
    /// its frame via `PreferenceKey`; (3) `TerminalHostStore.updatePlacements`
    /// unhides the view. The Task is scheduled inside the same runloop
    /// turn that triggered focus, so step 1 may not have happened yet —
    /// hence the first 16 ms tick. The 800 ms tail catches slow cold
    /// launches where the first preference-key emission carries a stale
    /// frame and the geometry-settling backstop in `TerminalPlaceholderView`
    /// is the one that finally unhides the view.
    static func focusWhenReady(tab: TabRuntime) {
        if focus(tab: tab) { return }
        Task { @MainActor [weak tab] in
            let delays: [Duration] = [
                .milliseconds(16),
                .milliseconds(50),
                .milliseconds(150),
                .milliseconds(400),
                .milliseconds(800),
            ]
            for delay in delays {
                try? await Task.sleep(for: delay)
                guard let tab else { return }
                if focus(tab: tab) { return }
            }
            logger.debug("focus skipped: tab \(tab?.id.uuidString ?? "<gone>", privacy: .public) had no visible AppTerminalView after \(delays.count, privacy: .public) retries")
        }
    }
}
