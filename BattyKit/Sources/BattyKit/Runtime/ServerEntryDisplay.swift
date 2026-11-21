// ServerEntryDisplay.swift

import BattyXPCCore
import Foundation

/// Pure text and visibility rules for the toolbar's Servers list.
public enum ServerEntryDisplay {
    public enum TailnetMenuAction: Equatable, Sendable {
        case share, stop, adoptedNote
    }

    /// The row menu's tailnet item. An adopted mapping is never offered Stop.
    public static func tailnetMenuAction(hasURL: Bool, adopted: Bool, offersSharing: Bool) -> TailnetMenuAction? {
        if hasURL { return adopted ? .adoptedNote : .stop }
        return offersSharing ? .share : nil
    }

    public enum Tone: Equatable, Sendable {
        case neutral, good, warning, bad
    }

    public static func stateText(_ state: ServerEntryState, isResponding: Bool?, kind: ServerBackendKind) -> String {
        let shared = kind == .external
        switch state {
        case .listening where kind == .inApp:
            return String(localized: "Serving", comment: "Servers list state: Batty's own static server is serving")
        case .starting:
            return shared
                ? String(localized: "Not listening", comment: "Servers list state: nothing listens on a shared server's port")
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

    /// The wire kind; the in-app server is `static`.
    public static func kind(_ kind: ServerBackendKind) -> ServerKind {
        switch kind {
        case .terminal: .terminal
        case .external: .external
        case .inApp: .static
        }
    }

    /// An entry's wire kind: a photon serve is `photon`.
    public static func kind(for entry: ServerEntry) -> ServerKind {
        entry.served?.engine == .photon ? .photon : kind(entry.backend.kind)
    }

    /// The Servers row's engine label for a `server serve` entry.
    public static func engineText(_ engine: ServeEngine?) -> String? {
        switch engine {
        case .photon: String(localized: "PhotonHTTP", comment: "Servers list: the folder is served by PhotonHTTP's photon command")
        case .builtin: String(localized: "Built-in", comment: "Servers list: the folder is served by Batty's built-in static server")
        case nil: nil
        }
    }

    /// The row's name: `--name`, else the served folder, else the command's
    /// program, else the port.
    public static func name(for entry: ServerEntry) -> String {
        if let custom = entry.customName, !custom.isEmpty { return custom }
        if let root = entry.served?.root {
            let name = URL(fileURLWithPath: root).lastPathComponent
            if !name.isEmpty { return name }
        }
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
