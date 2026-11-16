// ExitDispatcher.swift

import Foundation
import os

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "ExitDispatcher")

/// Types `exit` and presses Return in the focused Terminal Session, the same
/// as the user typing it. The text is pasted with no newline and followed by
/// a real Return key press, because under bracketed paste (on by default in
/// zsh) a pasted newline lands in the shell's edit line instead of running.
/// Per existing terminal-lifecycle rules this ends the foreground shell and
/// closes the tab/pane once the process exits; no new teardown work is
/// needed here.
///
/// Sent unconditionally, with no check of what the foreground process
/// actually is: if a full-screen program (vim, ssh, a REPL) is running
/// instead of a shell, `exit` and Return are typed into that program exactly
/// as they would be if the user typed them. libghostty offers no cheap way
/// to inspect the foreground process from this send path, and "type what the
/// user asked for" matches the feature's stated intent (#0309).
@MainActor
public enum ExitDispatcher {
    /// No-ops when no Terminal pane is focused (no registered window, no
    /// selected session, a non-`.terminal`-kind focused pane, or a pane
    /// transiently without an active tab) — mirrors `PasteDispatcher`'s
    /// target resolution exactly, because both now delegate to the same
    /// `AppStateStore.focusedTerminalTab` (#0332 — previously two
    /// independently hand-copied expressions, and they had already drifted
    /// out of sync once). Also no-ops while a sheet is attached to the
    /// target Window (`AppStateStore.menuTargetWindow`).
    public static func sendExit(store: AppStateStore?) {
        guard let store, let tab = focusedTerminalTab(in: store) else { return }
        typeExit(into: tab)
    }

    /// For callers that already hold their target Window and may run while
    /// their own sheet is still attached (the Command Palette).
    public static func sendExit(in window: WindowRuntime?) {
        guard let tab = AppStateStore.focusedTerminalTab(in: window) else { return }
        typeExit(into: tab)
    }

    /// Injectable seam, not `private`: a test cannot observe PTY bytes, so it
    /// swaps in a recorder to see what Exit Shell pastes and which keys it
    /// presses.
    static var inputSink: (TabRuntime) -> any TerminalInputSink = {
        TerminalViewStateInputSink(tab: $0)
    }

    private static func typeExit(into tab: TabRuntime) {
        guard inputSink(tab).runLine("exit") else {
            logger.error("Exit Shell not delivered: terminal surface refused input")
            return
        }
    }

    // Not `private` — ExitDispatcherTests exercises resolution directly
    // against this production code rather than re-typing the expression.
    static func focusedTerminalTab(in store: AppStateStore) -> TabRuntime? {
        store.focusedTerminalTab
    }
}
