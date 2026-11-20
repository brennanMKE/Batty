// MCPInstructions.swift

import BattyCLICore
import Foundation

/// The `instructions` an MCP host receives on `initialize`: who the agent is
/// in Batty, from `BATTY_*`, and which tool fits which task.
nonisolated enum MCPInstructions {
    /// Renders only when every tool exists; `argument` and `value` are
    /// checked against `tools[0]`, so a renamed verb drops out of the text.
    struct Hint: Sendable, Equatable {
        let tools: [String]
        let argument: String?
        let value: String?
        let line: String
    }

    static let hints: [Hint] = [
        Hint(tools: ["pane_split"], argument: "view", value: "git-status",
             line: "Status (git, processes, system metrics, LM Studio): `pane_split` with `view` (`git-status`, `process-status`, `system-metrics`, `lm-studio-dashboard`) and `unique: true`, not printed output."),
        Hint(tools: ["pane_split"], argument: "command", value: nil,
             line: "A command in a new Pane: `pane_split` with `command`."),
        Hint(tools: ["server_start", "server_share"], argument: nil, value: nil,
             line: "Dev servers: `server_start` (or `server_share` if one already runs); don't open a browser yourself."),
        Hint(tools: ["server_serve"], argument: "open", value: nil,
             line: "Static sites: `server_serve` with `open: true`, never `python3 -m http.server`."),
        Hint(tools: ["notify"], argument: nil, value: nil,
             line: "Get the user's attention: `notify`."),
        Hint(tools: ["session_remind"], argument: nil, value: nil,
             line: "Something for later: `session_remind`."),
        Hint(tools: ["pane_close", "session_close"], argument: nil, value: nil,
             line: "Close the Panes and Sessions you open when done (`pane_close`, `session_close`)."),
    ]

    static func applicableHints(catalog: MCPToolCatalog) -> [Hint] {
        hints.filter { hint in
            guard hint.tools.allSatisfy({ catalog.tool(named: $0) != nil }),
                  let first = hint.tools.first, let verb = catalog.verb(forToolName: first)
            else { return false }
            guard let argument = hint.argument else { return true }
            guard let property = verb.inputSchema.properties[argument] else { return false }
            guard let value = hint.value, let allowed = property.enumValues else { return true }
            return allowed.contains(value)
        }
    }

    static func text(environment: [String: String], catalog: MCPToolCatalog, cliName: String) -> String {
        let outside = "You are not running in a Batty Pane (no BATTY_* environment). These tools act on Batty's focused Session, Tab or Pane unless you pass ids; use them only when the user asks for Batty."
        var lines: [String]
        switch AgentContextNote.resolve(environment: environment) {
        case let .inBatty(context):
            lines = AgentContextNote.identityLines(context: context)
            lines.append("Tools given no Session, Tab or Pane act on this Pane.")
        case .notInBatty:
            lines = [outside]
        case let .incomplete(description):
            lines = [outside, "BATTY_* is incomplete (\(description)); pass ids explicitly."]
        }
        lines.append("These tools mirror the `\(cliName)` CLI (tool name = verb path with underscores); call `capabilities` for the full vocabulary.")
        lines += applicableHints(catalog: catalog).map { "- " + $0.line }
        return lines.joined(separator: "\n")
    }
}
