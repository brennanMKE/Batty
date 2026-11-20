// AgentMCPConfigSnippets.swift

import Foundation

/// Pure renderers for each agent host's Batty MCP configuration, shared by
/// `agent install` and the published snippets in `website/docs/snippets/`.
/// The site files are regenerated with `tools/build-agent-snippets.sh` and
/// guarded by `AgentMCPConfigSnippetsSiteTests`.
public nonisolated enum AgentMCPConfigSnippets {
    public static let serverArguments = ["mcp"]

    public static func openCodeEntry(command: String) -> AgentJSON {
        .object([
            ("type", .string("local")),
            ("command", .array(([command] + serverArguments).map(AgentJSON.string))),
            ("enabled", .bool(true)),
        ])
    }

    /// The `mcpServers` entry shape shared by Cursor's `mcp.json` and the Claude Code plugin's `.mcp.json`.
    public static func mcpServersEntry(command: String) -> AgentJSON {
        .object([
            ("command", .string(command)),
            ("args", .array(serverArguments.map(AgentJSON.string))),
        ])
    }

    public static func codexBlock(key: String, cliCommandName: String, command: String, lineEnding: String = "\n") -> String {
        CodexConfigBlock.lines(key: key, cliCommandName: cliCommandName, command: command)
            .map { $0 + lineEnding }.joined()
    }

    public static func claudeMCPAddCommand(key: String, command: String) -> String {
        (["claude", "mcp", "add", "--scope", "user", key, "--", command] + serverArguments)
            .map(AgentGuidanceInstaller.shellQuoted).joined(separator: " ")
    }

    public static func pluginInstallCommand(cliCommandName: String) -> String {
        "\(cliCommandName) agent install"
    }

    public static func configDocument(keyPath: [String], entry: AgentJSON) throws -> Data {
        try AgentGuidanceInstaller.freshConfigData(keyPath: keyPath, entry: entry)
    }

    public struct SiteFile: Sendable, Equatable {
        public let name: String
        public let contents: String
    }

    public static func siteFiles(cliCommandName cli: String = "batty") throws -> [SiteFile] {
        func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }
        return [
            SiteFile(name: "claude-code-plugin.txt", contents: pluginInstallCommand(cliCommandName: cli) + "\n"),
            SiteFile(name: "claude-code-mcp-add.txt", contents: claudeMCPAddCommand(key: cli, command: cli) + "\n"),
            SiteFile(name: "codex-config.toml", contents: codexBlock(key: cli, cliCommandName: cli, command: cli)),
            SiteFile(name: "cursor-mcp.json", contents: text(try configDocument(keyPath: ["mcpServers", cli], entry: mcpServersEntry(command: cli)))),
            SiteFile(name: "opencode.json", contents: text(try configDocument(keyPath: ["mcp", cli], entry: openCodeEntry(command: cli)))),
            SiteFile(name: "global-instructions-prompt.txt", contents: AgentGlobalInstructionsPrompt.text + "\n"),
        ]
    }
}
