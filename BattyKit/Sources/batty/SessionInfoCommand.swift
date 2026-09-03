// SessionInfoCommand.swift

import ArgumentParser
import BattyCLICore
import BattyXPCCore
import Foundation

/// `batty session` — the noun #0257's eventual grammar (`session new`,
/// `session rename`, `session close`) will grow siblings under. `info`
/// (#0274) and `focus` (#0381) exist today.
struct SessionNounCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "session",
        abstract: "Inspect or control a Batty session.",
        subcommands: [SessionInfoCommand.self, SessionFocusCommand.self]
    )
}

/// `batty session info` — the calling/target session's topology slice
/// (#0274), the single-session shape `batty list` nests.
///
/// **Target resolution retrofit (#0281):** `resolveSessionID()` below now
/// runs the shared `BattyTargetResolver` chain — `--session` flag →
/// `BATTY_SESSION_ID` env var → `nil` (the app's focused-session
/// resolution) — completing the seam #0274 deliberately left here (see that
/// issue's Resolution notes). `AppStateStore.sessionInfoPayload(sessionID:)`
/// already accepts `nil` as "no explicit target," so nothing app-side
/// changed.
struct SessionInfoCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "info",
        abstract: "Report the calling/target session's topology slice."
    )

    @Option(name: .long, help: "Session id to inspect. Falls back to the focused session when omitted.")
    var session: String?


    @Flag(name: .long, help: "Emit JSON instead of a plain-text summary.")
    var json = false

    @Flag(name: .long, help: "Include `frame` and `visibleRect` dimensions in pane objects. Not included by default.")
    var includeDimensions = false

    nonisolated func run() throws {
        let sessionID = try resolveSessionID()

        switch AppConnectDance.resolveEndpoint() {
        case .failure(.brokerUnreachable):
            fputs("batty: broker unreachable\n", stderr)
            throw ExitCode(XPCExitCode.brokerUnreachable)
        case .failure(.appUnavailable):
            fputs("batty: app unavailable\n", stderr)
            throw ExitCode(XPCExitCode.appUnavailable)
        case .failure(.appRunningUnregistered):
            fputs("batty: Batty is running but isn't responding to the broker — try relaunching it\n", stderr)
            throw ExitCode(XPCExitCode.appRunningUnregistered)
        case .failure(.appBundleUnresolved(let message)):
            fputs("batty: \(message)\n", stderr)
            throw ExitCode(XPCExitCode.appBundleUnresolved)
        case .success(let endpoint):
            switch AppServiceClient.sessionInfo(endpoint: endpoint, sessionID: sessionID, includeDimensions: includeDimensions, timeout: 3.0) {
            case .success(let payload):
                if json {
                    try Self.printJSON(payload)
                } else {
                    Self.printPlainText(payload, includeDimensions: includeDimensions)
                }
            case .unreachable:
                fputs("batty: app unavailable\n", stderr)
                throw ExitCode(XPCExitCode.appUnavailable)
            case .requestFailed(let message):
                fputs("batty: request failed — \(message)\n", stderr)
                throw ExitCode(XPCExitCode.requestFailed)
            case .appTerminated:
                fputs("batty: app terminated\n", stderr)
                throw ExitCode(XPCExitCode.sessionTerminated)
            }
        }



    }

    /// `--session` flag → `BATTY_SESSION_ID` env → `nil`, meaning "let the
    /// app resolve the focused session."
    private func resolveSessionID() throws -> UUID? {
        switch BattyTargetResolver.resolve(flag: session, environmentKey: .sessionID) {
        case let .success(id):
            return id
        case let .failure(.malformedFlag(raw)):
            fputs("batty: invalid --session id: \(raw)\n", stderr)
            throw ExitCode.failure
        }
    }

    private static func printJSON(_ payload: TopologySessionPayload) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(payload), let text = String(data: data, encoding: .utf8) else {
            fputs("batty: failed to encode session as JSON\n", stderr)
            throw ExitCode.failure
        }
        print(text)
    }

    




    private static func printPlainText(_ payload: TopologySessionPayload, includeDimensions: Bool) {
        let flags = payload.isActive ? " active" : ""
        let path = payload.path.map { " path=\($0)" } ?? ""
        print("session \(payload.id) \"\(payload.name)\"\(flags)\(path)")
        for pane in payload.allPanes {
            var paneFlags: [String] = []
            if pane.isHidden { paneFlags.append("hidden") }
            if pane.isFocused { paneFlags.append("focused") }
            var dims = ""
            if includeDimensions {
                if let frame = pane.frame {
                    dims += " frame=\(frame.x),\(frame.y),\(frame.width)x\(frame.height)"
                }
                if let visibleRect = pane.visibleRect {
                    dims += " visible=\(visibleRect.x),\(visibleRect.y),\(visibleRect.width)x\(visibleRect.height)"
                }
            }
            let paneFlagText = paneFlags.isEmpty ? "" : " " + paneFlags.joined(separator: " ")
            print("  pane \(pane.id) kind=\(pane.kind?.rawValue ?? "unknown")\(paneFlagText)\(dims)")
            for tab in pane.tabs {
                let tabFlags = tab.isActive ? " active" : ""
                let cwd = tab.workingDirectory.map { " cwd=\($0)" } ?? ""
                print("    tab \(tab.id) \"\(tab.title)\"\(tabFlags)\(cwd)")
            }
        }
    }



}

/// `batty session focus` — #0381: one of the three "show the human what I
/// did" verbs, over XPC request/reply following #0282's mutation-verb
/// pattern so a stale/unknown id is visible to the caller (exit `4`)
/// instead of silently swallowed.
///
/// **Activating**, unlike every other mutation verb: #0257's 2026-07-27
/// terminology amendment names the `focus` verbs as the CLI's one
/// sanctioned exception to "a mutation aimed at a background session must
/// not switch the active session." Focusing a session that isn't the
/// window's selected session selects it, and brings the containing window
/// forward (the same bring-forward chain a Bell Feed click-to-jump uses).
struct SessionFocusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "focus",
        abstract: "Select a session and activate its window.",
        discussion: """
        Selects the target session (making it the window's active session) \
        and brings its window forward. This is one of the CLI's sanctioned \
        focus-stealing exceptions (#0257): every other mutation verb aimed \
        at a background session leaves the active session untouched, but \
        focus verbs exist specifically to bring what an agent did to the \
        human's attention. Only id-based targeting is implemented; \
        name-based targeting (`<name>`) is not.
        """,
        helpNames: .long
    )

    @Argument(help: "Session id to focus. Falls back to BATTY_SESSION_ID, then the focused session, when omitted.")
    var id: String?

    nonisolated func run() throws {
        let targetSessionID = try resolveTargetSessionID(flag: id)

        switch AppConnectDance.resolveEndpoint() {
        case .failure(.brokerUnreachable):
            fputs("batty: broker unreachable\n", stderr)
            throw ExitCode(XPCExitCode.brokerUnreachable)
        case .failure(.appUnavailable):
            fputs("batty: app unavailable\n", stderr)
            throw ExitCode(XPCExitCode.appUnavailable)
        case .failure(.appRunningUnregistered):
            fputs("batty: Batty is running but isn't responding to the broker — try relaunching it\n", stderr)
            throw ExitCode(XPCExitCode.appRunningUnregistered)
        case .failure(.appBundleUnresolved(let message)):
            fputs("batty: \(message)\n", stderr)
            throw ExitCode(XPCExitCode.appBundleUnresolved)
        case .success(let endpoint):
            switch AppServiceClient.sessionFocus(endpoint: endpoint, sessionID: targetSessionID, timeout: 3.0) {
            case .success:
                break
            case .unreachable:
                fputs("batty: app unavailable\n", stderr)
                throw ExitCode(XPCExitCode.appUnavailable)
            case .requestFailed(let message):
                fputs("batty: request failed — \(message)\n", stderr)
                throw ExitCode(XPCExitCode.requestFailed)
            case .appTerminated:
                fputs("batty: app terminated\n", stderr)
                throw ExitCode(XPCExitCode.sessionTerminated)
            }
        }
    }

    /// `<id>` argument → `BATTY_SESSION_ID` env → `nil` (let the app
    /// resolve the focused session). Same chain shape as `SessionInfoCommand
    /// .resolveSessionID()`, driven by a positional argument rather than a
    /// `--session` flag — a focus verb's whole purpose is naming a target,
    /// so it reads as `batty session focus <id>`, not `batty session focus
    /// --session <id>`.
    private nonisolated func resolveTargetSessionID(flag: String?) throws -> UUID? {
        switch BattyTargetResolver.resolve(flag: flag, environmentKey: .sessionID) {
        case let .success(id):
            return id
        case let .failure(.malformedFlag(raw)):
            fputs("batty: invalid session id: \(raw)\n", stderr)
            throw ExitCode.failure
        }
    }
}
