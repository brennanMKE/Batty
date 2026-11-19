// AgentGlobalInstructionsPrompt.swift

import Foundation

/// The prompt a user gives their agent so the agent adds or updates the Batty
/// section in its own global instructions file. Batty never writes that file.
public nonisolated enum AgentGlobalInstructionsPrompt {
    public struct Destination: Sendable, Equatable {
        public let agent: String
        public let path: String
    }

    public static let destinations: [Destination] = [
        Destination(agent: "Claude Code", path: "~/.claude/CLAUDE.md"),
        Destination(agent: "Codex", path: "~/.codex/AGENTS.md"),
        Destination(agent: "OpenCode", path: "~/.config/opencode/AGENTS.md"),
    ]

    public static let ignoreLine = "If those variables are not set, you are not in Batty; ignore this section."

    public static let note: String = {
        let lines = [
            "## Batty",
            "",
            "At the start of a session, run `env | grep '^BATTY'`. If `BATTY_SESSION_ID`, `BATTY_TAB_ID` and `BATTY_PANE_ID` are set, you are running in a terminal Pane of Batty, a macOS terminal multiplexer, and can drive it:",
            "",
            "- Prefer the `batty` MCP tools (`batty-beta` in Batty Beta) when they are available (`batty mcp`, installed by `batty agent install`). Otherwise use the CLI: `batty` (or `batty-beta` in Batty Beta). Run `batty capabilities` to see the available commands.",
            "- Use Batty to split Panes and set reminders (`batty session remind`) when they help the user follow your work.",
        ] + AgentContextNote.ruleLines(cliName: "batty") + [
            "",
            ignoreLine,
        ]
        return lines.joined(separator: "\n")
    }()

    public static let text: String = {
        let bullets = destinations.map { "- \($0.agent): `\($0.path)`" }
        let lines = [
            "Add Batty to your global instructions, the file you read at the start of every session:",
            "",
        ] + bullets + [
            "- Cursor has no such file: show me the section below so I can paste it into Cursor's User Rules (Cursor Settings → Rules).",
            "",
            "If the file does not exist, create it. If it already has a `## Batty` section, replace that whole section, from its heading up to the next `## ` heading or the end of the file, with the text below; do not add a second one. Change nothing else in the file. Then tell me which file you changed.",
            "",
            "```markdown",
            note,
            "```",
        ]
        return lines.joined(separator: "\n")
    }()
}
