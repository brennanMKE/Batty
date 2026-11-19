// AgentContextNote.swift

import Foundation

/// The note telling an AI agent it is in a Batty Pane, built from `BATTY_*`
/// alone, and the rule lines it shares with ``ProjectAgentSnippet``.
public nonisolated enum AgentContextNote {
    public static func ruleLines(cliName: String) -> [String] {
        [
            "- Show status in Batty Panes (`\(cliName) pane split --view git-status --unique`) rather than printing it.",
            "- Start dev servers with `\(cliName) server start --port N -- <command>` (or `\(cliName) server attach --port N` if one is already running) when `\(cliName) capabilities` lists it. Don't open a browser yourself; pass `--split` only when the user asked for a placement.",
            "- Preview static pages with `\(cliName) server serve <dir> --open`, never `python3 -m http.server`.",
            "- Use `\(cliName) notify` to get the user's attention.",
            "- Close the Panes and Sessions you open when you are done with them.",
        ]
    }

    public static func identityLines(context: BattyIdentityContext) -> [String] {
        [
            "You are running in a terminal Pane of Batty, a macOS terminal multiplexer.",
            "Session: \(context.sessionID.uuidString)",
            "Tab: \(context.tabID.uuidString)",
            "Pane: \(context.paneID.uuidString)",
        ]
    }

    public static func header(context: BattyIdentityContext, cliName: String) -> String {
        identityLines(context: context).joined(separator: "\n") + "\n" + """
        Drive Batty with the `\(cliName)` MCP tools when they are available, otherwise the `\(cliName)` CLI (run `\(cliName) capabilities` first). Tools and commands given no Session, Tab or Pane act on this Pane.
        """
    }

    public static func text(context: BattyIdentityContext, cliName: String) -> String {
        header(context: context, cliName: cliName) + "\n\n" + ruleLines(cliName: cliName).joined(separator: "\n")
    }

    public enum Resolution: Equatable, Sendable {
        case inBatty(BattyIdentityContext)
        case notInBatty
        case incomplete(String)
    }

    /// No default environment, so a test can never read the runner's own.
    public static func resolve(environment: [String: String]) -> Resolution {
        switch BattyIdentityContext.resolve(from: environment) {
        case let .success(context):
            return .inBatty(context)
        case let .failure(error):
            if case let .missing(keys) = error, Set(keys) == Set(BattyContextEnvironmentKey.allCases) {
                return .notInBatty
            }
            return .incomplete(error.description)
        }
    }

    public struct Payload: Codable, Equatable, Sendable {
        public var inBatty: Bool
        public var sessionID: UUID?
        public var tabID: UUID?
        public var paneID: UUID?
        public var cli: String?
        public var note: String?
    }

    public struct Output: Equatable, Sendable {
        public var stdout: String?
        public var stderr: String?

        public init(stdout: String?, stderr: String?) {
            self.stdout = stdout
            self.stderr = stderr
        }
    }

    /// The whole `agent context` command as a pure function. Never an error
    /// exit: a session-start hook must not fail the agent's startup.
    public static func render(environment: [String: String], cliName: String, json: Bool) -> Output {
        let payload: Payload
        var stderr: String?
        switch resolve(environment: environment) {
        case let .inBatty(context):
            if !json { return Output(stdout: text(context: context, cliName: cliName), stderr: nil) }
            payload = Payload(inBatty: true, sessionID: context.sessionID, tabID: context.tabID, paneID: context.paneID, cli: cliName, note: text(context: context, cliName: cliName))
        case .notInBatty:
            if !json { return Output(stdout: nil, stderr: nil) }
            payload = Payload(inBatty: false)
        case let .incomplete(description):
            stderr = "batty: no Batty context: \(description)"
            if !json { return Output(stdout: nil, stderr: stderr) }
            payload = Payload(inBatty: false)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = (try? encoder.encode(payload)) ?? Data(#"{"inBatty" : false}"#.utf8)
        return Output(stdout: String(decoding: data, as: UTF8.self), stderr: stderr)
    }
}
