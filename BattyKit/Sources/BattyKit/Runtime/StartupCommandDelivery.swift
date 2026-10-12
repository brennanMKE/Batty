// StartupCommandDelivery.swift

import Foundation
import GhosttyTerminal
import os

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "StartupCommandDelivery")

/// Where a startup command's keystrokes go. `TerminalViewState` in
/// production; a recording stand-in in tests.
@MainActor
protocol StartupInputSink: AnyObject {
    func paste(text: String) -> Bool
    func pressReturn() -> Bool
}

/// Deliberately goes through the Tab's `TerminalViewState`, not its
/// `AppTerminalView`: the view's `sendKey` commits an open IME composition
/// before the key, which would put the user's half-typed text on the line
/// that Return then runs. The view state's path leaves a composition alone.
@MainActor
final class TerminalStartupInputSink: StartupInputSink {
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

/// A Project Tab's startup command, delivered to its shell as typed input.
/// `paste(text:)` is a bracketed paste, so a trailing newline would land in
/// the edit line instead of running it; each line is therefore pasted and
/// then followed by a real Return key press. Delivery happens at most once.
@MainActor
final class StartupCommandDelivery {
    private let lines: [String]
    private let sink: any StartupInputSink
    private(set) var isDelivered = false
    private(set) var isFinished = false
    private var finishedWaiters: [CheckedContinuation<Void, Never>] = []

    init(command: String, sink: any StartupInputSink) {
        self.lines = Self.lines(from: command)
        self.sink = sink
    }

    /// One entry per non-blank line; a multi-line command is sent line by
    /// line. Control characters are dropped so the text cannot end the
    /// bracketed paste early (ESC) or smuggle a keystroke, and so are Unicode
    /// format characters (bidi overrides, zero-width joiners) so the text the
    /// user approves reads the way it runs.
    static func lines(from command: String) -> [String] {
        command
            .components(separatedBy: .newlines)
            .map { line in
                String(String.UnicodeScalarView(line.unicodeScalars.filter {
                    $0 == "\t" || !(CharacterSet.controlCharacters.contains($0)
                        || $0.properties.generalCategory == .format)
                }))
            }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// Takes the delivery's turn on the main queue instead of running inside
    /// the caller. The caller is libghostty's working-directory action
    /// callback, which runs while `ghostty_app_tick` drains the app mailbox;
    /// pasting and pressing a key from inside it would re-enter libghostty
    /// from its own callback. Terminal input is not an observed-state write,
    /// so the hop is safe where a `Task` hop around one would not be.
    func deliverOnNextMainTurn() {
        DispatchQueue.main.async { [self] in
            deliver()
            finish()
        }
    }

    /// Returns once delivery has run (or been refused). Immediately if it
    /// already has.
    func waitUntilFinished() async {
        if isFinished { return }
        await withCheckedContinuation { finishedWaiters.append($0) }
    }

    private func finish() {
        isFinished = true
        let waiters = finishedWaiters
        finishedWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    @discardableResult
    private func deliver() -> Bool {
        guard !isDelivered else { return false }
        isDelivered = true
        for line in lines {
            guard sink.paste(text: line), sink.pressReturn() else {
                logger.error("startup command not delivered: terminal surface refused input")
                return false
            }
        }
        return true
    }
}
