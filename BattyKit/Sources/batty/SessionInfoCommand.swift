// SessionInfoCommand.swift

import ArgumentParser
import BattyXPCCore
import Foundation

/// `batty session` — the noun #0257's eventual grammar (`session new`,
/// `session rename`, `session focus`, `session close`) will grow siblings
/// under. Only `info` (#0274) exists today.
struct SessionNounCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "session",
        abstract: "Inspect or control a Batty session.",
        subcommands: [SessionInfoCommand.self]
    )
}

/// `batty session info` — the calling/target session's topology slice
/// (#0274), the single-session shape `batty list` nests.
///
/// **Target resolution seam for #0257:** the eventual resolution order is
/// `--session` flag → `BATTY_SESSION_ID` env var → focused session. None of
/// #0257's context groundwork (the env var, `whoami`, client-generated ids)
/// exists yet, so only the first and last steps are implemented here — an
/// explicit `--session <id>` flag, falling straight through to the app's
/// focused-session resolution when omitted. When #0257 lands, its env-var
/// read slots in as a middle branch in `resolveSessionID()` below, between
/// the flag check and the `nil` fallthrough; nothing else in this file (or
/// in `AppStateStore.sessionInfoPayload(sessionID:)`, which already accepts
/// `nil` as "no explicit target") needs to change.
struct SessionInfoCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "info",
        abstract: "Report the calling/target session's topology slice."
    )

    @Option(name: .long, help: "Session id to inspect. Falls back to the focused session when omitted.")
    var session: String?

    @Flag(name: .long, help: "Emit JSON instead of a plain-text summary.")
    var json = false

    nonisolated func run() throws {
        let sessionID = try resolveSessionID()

        switch AppConnectDance.resolveEndpoint() {
        case .failure(.brokerUnreachable):
            fputs("batty: broker unreachable\n", stderr)
            throw ExitCode(XPCExitCode.brokerUnreachable)
        case .failure(.appUnavailable):
            fputs("batty: app unavailable\n", stderr)
            throw ExitCode(XPCExitCode.appUnavailable)
        case .success(let endpoint):
            switch AppServiceClient.sessionInfo(endpoint: endpoint, sessionID: sessionID, timeout: 3.0) {
            case .success(let payload):
                if json {
                    try Self.printJSON(payload)
                } else {
                    Self.printPlainText(payload)
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

    /// `--session` flag → (seam: #0257's `BATTY_SESSION_ID` lands here) →
    /// `nil`, meaning "let the app resolve the focused session."
    private func resolveSessionID() throws -> UUID? {
        guard let session else { return nil }
        guard let parsed = UUID(uuidString: session) else {
            fputs("batty: invalid --session id: \(session)\n", stderr)
            throw ExitCode.failure
        }
        return parsed
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

    private static func printPlainText(_ payload: TopologySessionPayload) {
        let flags = payload.isActive ? " active" : ""
        let path = payload.path.map { " path=\($0)" } ?? ""
        print("session \(payload.id) \"\(payload.name)\"\(flags)\(path)")
        for pane in payload.allPanes {
            var paneFlags: [String] = []
            if pane.isHidden { paneFlags.append("hidden") }
            if pane.isFocused { paneFlags.append("focused") }
            let paneFlagText = paneFlags.isEmpty ? "" : " " + paneFlags.joined(separator: " ")
            print("  pane \(pane.id)\(paneFlagText)")
            for tab in pane.tabs {
                let tabFlags = tab.isActive ? " active" : ""
                let cwd = tab.workingDirectory.map { " cwd=\($0)" } ?? ""
                print("    tab \(tab.id) \"\(tab.title)\"\(tabFlags)\(cwd)")
            }
        }
    }
}
