// ServerEntryDisplay.swift

import Foundation

/// Pure text and visibility rules for the toolbar's Servers list.
public enum ServerEntryDisplay {
    public enum Tone: Equatable, Sendable {
        case neutral, good, warning, bad
    }

    public static func stateText(_ state: ServerEntryState, isResponding: Bool?, kind: ServerBackendKind) -> String {
        let attach = kind == .external
        switch state {
        case .listening where kind == .inApp:
            return String(localized: "Serving", comment: "Servers list state: Batty's own static server is serving")
        case .starting:
            return attach
                ? String(localized: "Not listening", comment: "Servers list state: attach found nothing on the port")
                : String(localized: "Starting", comment: "Servers list state")
        case .listening(let pid):
            if isResponding == false { return String(localized: "Not responding", comment: "Servers list state: listening but the HTTP probe failed") }
            return pid == nil
                ? String(localized: "Listening, owned by another user", comment: "Servers list state")
                : String(localized: "Listening", comment: "Servers list state")
        case .stopping:
            return String(localized: "Stopping", comment: "Servers list state")
        case .stopped(_, .requested):
            return String(localized: "Stopped", comment: "Servers list state")
        case .stopped(_, .terminalClosed):
            return String(localized: "Stopped, terminal closed", comment: "Servers list state")
        case .crashed(let code?) where code == 0:
            return String(localized: "Exited (0)", comment: "Servers list state: the command exited 0 without a Stop")
        case .crashed(let code?):
            return String(localized: "Crashed (\(code))", comment: "Servers list state; the argument is the exit code")
        case .crashed(nil):
            return String(localized: "Crashed", comment: "Servers list state with no exit code")
        }
    }

    public static func tone(_ state: ServerEntryState, isResponding: Bool?) -> Tone {
        switch state {
        case .listening: isResponding == false ? .warning : .good
        case .stopping: .warning
        case .crashed(let code): code == 0 ? .neutral : .bad
        case .starting, .stopped: .neutral
        }
    }

    public static func showsRestart(canRestart: Bool) -> Bool { canRestart }

    public static func showsStop(_ state: ServerEntryState, canStop: Bool, kind: ServerBackendKind) -> Bool {
        if case .listening(nil) = state, kind != .inApp { return false }
        return canStop
    }

    /// Only servers Batty started (a terminal Pane's command or the in-app
    /// static server) offer Stop and Restart in the list.
    public static func offersStopAndRestart(kind: ServerBackendKind) -> Bool {
        kind != .external
    }

    public static func address(port: UInt16) -> String {
        "127.0.0.1:\(port)"
    }

    /// The row's name: the served folder, else the command's program, else
    /// the port.
    public static func name(for entry: ServerEntry) -> String {
        if let inApp = entry.backend as? InAppStaticServerBackend {
            let name = URL(fileURLWithPath: inApp.root).lastPathComponent
            if !name.isEmpty { return name }
        }
        if let program = programName(entry.backend.command) ?? programName(entry.recoveredCommandLine) {
            return program
        }
        return String(localized: "Port \(String(entry.port))", comment: "Servers list: row name when nothing else names the server; the argument is the port")
    }

    static func programName(_ commandLine: String?) -> String? {
        guard let first = commandLine?.split(whereSeparator: { $0 == " " || $0 == "\t" }).first else { return nil }
        let program = (String(first) as NSString).lastPathComponent
        return program.isEmpty ? nil : program
    }
}
