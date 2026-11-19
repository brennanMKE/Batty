// ServerPaneDisplay.swift

import Foundation

/// Pure text and visibility rules for the Server Pane view.
public enum ServerPaneDisplay {
    public enum Tone: Equatable, Sendable {
        case neutral, good, warning, bad
    }

    public static func stateText(_ state: ServerPaneState, isResponding: Bool?, attach: Bool) -> String {
        switch state {
        case .starting:
            return attach
                ? String(localized: "Not listening", comment: "Server Pane state: attach found nothing on the port")
                : String(localized: "Starting", comment: "Server Pane state")
        case .listening(let pid):
            if isResponding == false { return String(localized: "Not responding", comment: "Server Pane state: listening but the HTTP probe failed") }
            return pid == nil
                ? String(localized: "Listening, owned by another user", comment: "Server Pane state")
                : String(localized: "Listening", comment: "Server Pane state")
        case .stopping:
            return String(localized: "Stopping", comment: "Server Pane state")
        case .stopped(_, .requested):
            return String(localized: "Stopped", comment: "Server Pane state")
        case .stopped(_, .terminalClosed):
            return String(localized: "Stopped, terminal closed", comment: "Server Pane state")
        case .crashed(let code?) where code == 0:
            return String(localized: "Exited (0)", comment: "Server Pane state: the command exited 0 without a Stop")
        case .crashed(let code?):
            return String(localized: "Crashed (\(code))", comment: "Server Pane state; the argument is the exit code")
        case .crashed(nil):
            return String(localized: "Crashed", comment: "Server Pane state with no exit code")
        }
    }

    public static func tone(_ state: ServerPaneState, isResponding: Bool?) -> Tone {
        switch state {
        case .listening: isResponding == false ? .warning : .good
        case .stopping: .warning
        case .crashed(let code): code == 0 ? .neutral : .bad
        case .starting, .stopped: .neutral
        }
    }

    public static func showsRestart(canRestart: Bool) -> Bool { canRestart }

    public static func showsStop(_ state: ServerPaneState, canStop: Bool) -> Bool {
        if case .listening(nil) = state { return false }
        return canStop
    }
}
