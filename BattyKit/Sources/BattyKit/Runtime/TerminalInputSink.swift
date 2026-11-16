// TerminalInputSink.swift

import Foundation
import GhosttyTerminal

/// Where typed terminal input goes. `TerminalViewState` in production; a
/// recording stand-in in tests.
@MainActor
protocol TerminalInputSink: AnyObject {
    func paste(text: String) -> Bool
    func pressReturn() -> Bool
}

extension TerminalInputSink {
    /// `paste(text:)` is a bracketed paste, so a newline inside it would stay
    /// in the shell's edit line instead of running it. The line is pasted
    /// without one, then a real Return runs it. `line` must contain no newline.
    func runLine(_ line: String) -> Bool {
        paste(text: line) && pressReturn()
    }
}

/// Deliberately goes through the Tab's `TerminalViewState`, not its
/// `AppTerminalView`: the view's `sendKey` commits an open IME composition
/// before the key, which would put the user's half-typed text on the line
/// that Return then runs. The view state's path leaves a composition alone.
@MainActor
final class TerminalViewStateInputSink: TerminalInputSink {
    private let terminal: TerminalViewState

    init(tab: TabRuntime) {
        self.terminal = tab.terminal
    }

    func paste(text: String) -> Bool {
        terminal.paste(text: text)
    }

    func pressReturn() -> Bool {
        terminal.sendKey(TerminalKeyPress(.enter))
    }
}
