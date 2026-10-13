// ExitDispatcher.swift

import Foundation

/// Sends the literal text `exit` followed by a newline into the focused
/// Terminal Session — the keyboard-shortcut equivalent of typing `exit` and
/// pressing Return. Per existing terminal-lifecycle rules this ends the
/// foreground shell and closes the tab/pane once the process exits; no new
/// teardown work is needed here.
///
/// Sent unconditionally, with no check of what the foreground process
/// actually is: if a full-screen program (vim, ssh, a REPL) is running
/// instead of a shell, `"exit\n"` is typed into that program exactly as it
/// would be if the user typed it themselves. libghostty offers no cheap way
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
    /// out of sync once).
    public static func sendExit(store: AppStateStore?) {
        guard let store, let tab = focusedTerminalTab(in: store) else { return }
        sendText(tab, "exit\n")
    }

    /// Injectable seam, not `private`: a test cannot observe PTY bytes, so it
    /// swaps in a recorder to prove Exit Shell sends nothing when no target
    /// resolves.
    static var sendText: (TabRuntime, String) -> Void = { tab, text in
        tab.terminal.send(text)
    }

    // Not `private` — ExitDispatcherTests exercises resolution directly
    // against this production code rather than re-typing the expression.
    static func focusedTerminalTab(in store: AppStateStore) -> TabRuntime? {
        store.focusedTerminalTab
    }
}
