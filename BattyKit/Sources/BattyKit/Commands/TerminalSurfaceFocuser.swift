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
        logger.debug("promote: tab=\(tab.id, privacy: .public)")
        window.makeFirstResponder(view)
        return true
    }

    /// Monotonic token per window. Each `focusWhenReady` call invalidates
    /// every pending promotion attempt (first or retry) from earlier calls
    /// in the same window, so only that window's newest focus intent can
    /// ever reach `makeFirstResponder`. Without this, a stale retry for the
    /// previously focused tab can re-promote it after focus has moved on,
    /// dragging the model back through the isFocused echo — the ping-pong
    /// loop behind #0229's crash and the focus-drag-back regression on the
    /// split tests (#0230). Keyed by window so a request in one window
    /// cannot cancel another window's ladder.
    private static var generations: [WindowID: Int] = [:]

    static func generation(for windowID: WindowID) -> Int {
        generations[windowID] ?? 0
    }

    /// Drops `windowID`'s token when its window closes. A ladder still in
    /// flight for that window then sees a mismatch and stops.
    static func forgetWindow(_ windowID: WindowID) {
        generations.removeValue(forKey: windowID)
    }

    /// Retry variant. Every attempt — including the first — runs on a
    /// subsequent main-actor turn, never synchronously. The only caller is
    /// `WindowRuntime.requestTerminalFocus`'s `focusTerminal` seam, reached
    /// from actions and from model setters (`SplitTree.focusedPaneID`,
    /// `PaneRuntime.activeTabID`). A setter can run from a binding or
    /// command inside SwiftUI's update, which `NSHostingView` can execute
    /// inside AppKit's layout pass; promoting first responder there
    /// re-enters layout and flips `isFocused` observables mid-pass (the
    /// #0229 crash class — see docs/swiftui-observation-rules.md). The hop
    /// is safe *only* because the window's generation guarantees a
    /// superseded promotion can never fire late.
    ///
    /// Why multiple retries: a newly inserted session's pane and its
    /// terminal `AppTerminalView` traverse three independent runloop turns
    /// before keystrokes can land: (1) SwiftUI mounts the placeholder and
    /// `TerminalHostStore.terminalView(for:)` creates and attaches the
    /// `AppTerminalView` (`isHidden = true`); (2) the placeholder reports
    /// its frame via `onGeometryChange`; (3) that first
    /// `TerminalHostStore.reportFrame` reveals the view of a Tab the actions
    /// marked shown. The 800 ms tail catches slow cold launches where the
    /// first geometry report carries a stale frame and a later
    /// `onGeometryChange` in `TerminalPlaceholderView` is the one that
    /// finally settles the view.
    static func focusWhenReady(tab: TabRuntime, in windowID: WindowID) {
        let requested = generation(for: windowID) + 1
        generations[windowID] = requested
        Task { @MainActor [weak tab] in
            // nil = no sleep: the first attempt still runs on a fresh
            // main-actor turn, just without added latency.
            let delays: [Duration?] = [
                nil,
                .milliseconds(16),
                .milliseconds(50),
                .milliseconds(150),
                .milliseconds(400),
                .milliseconds(800),
            ]
            for delay in delays {
                if let delay { try? await Task.sleep(for: delay) }
                guard requested == Self.generations[windowID] else { return }
                guard let tab else { return }
                if focus(tab: tab) { return }
            }
            logger.debug("focus skipped: tab \(tab?.id.uuidString ?? "<gone>", privacy: .public) had no visible AppTerminalView after \(delays.count - 1, privacy: .public) retries")
        }
    }
}
