// AgentPluginTree.swift

import Foundation

/// The Claude Code plugin marketplace tree, shared by `agent install`'s local
/// staging and the public marketplace repo (`tools/build-agent-downloads.py`).
/// The two differ only in the CLI path, the marketplace fields and whether the
/// marketplace entry repeats `version`.
public nonisolated enum AgentPluginTree {
    public static let publicRepository = "brennanMKE/batty-plugins"
    public static let publicMarketplaceName = "batty-plugins"
    public static let publicPluginName = "batty"
    public static let publicCLICommand = "batty"

    public struct File: Sendable, Equatable {
        /// Relative to the marketplace root.
        public let path: String
        public let data: Data

        public init(path: String, data: Data) {
            self.path = path
            self.data = data
        }
    }

    public struct Marketplace: Sendable {
        public let name: String
        public let description: String
        public let owner: [String: String]
        /// Claude Code's docs say to set `version` in `plugin.json` only; the
        /// local installer keeps it in both for byte-for-byte compatibility.
        public let entryCarriesVersion: Bool

        public init(name: String, description: String, owner: [String: String], entryCarriesVersion: Bool) {
            self.name = name
            self.description = description
            self.owner = owner
            self.entryCarriesVersion = entryCarriesVersion
        }
    }

    public static func files(
        pluginName: String,
        cliCommandName: String,
        cliCommand: String,
        version: String,
        skill: Data,
        marketplace: Marketplace
    ) throws -> [File] {
        let description = "Drive the Batty terminal multiplexer: the \(AgentGuidanceIdentity.skillName) skill and the `\(cliCommandName) mcp` server."
        var entry: [String: Any] = [
            "name": pluginName,
            "source": "./\(pluginName)",
            "description": description,
        ]
        if marketplace.entryCarriesVersion { entry["version"] = version }
        return [
            File(path: ".claude-plugin/marketplace.json", data: try jsonData([
                "name": marketplace.name,
                "description": marketplace.description,
                "owner": marketplace.owner,
                "plugins": [entry],
            ])),
            File(path: "\(pluginName)/.claude-plugin/plugin.json", data: try jsonData([
                "name": pluginName,
                "version": version,
                "description": description,
                "author": ["name": "Batty"],
            ])),
            File(path: "\(pluginName)/.mcp.json", data: try jsonData([
                "mcpServers": [pluginName: AgentMCPConfigSnippets.mcpServersEntry(command: cliCommand).foundation],
            ])),
            File(path: "\(pluginName)/hooks/hooks.json", data: try jsonData([
                "description": "Tell Claude Code it is running in a Batty Pane, and which one.",
                "hooks": ["SessionStart": [[
                    "hooks": [[
                        "type": "command",
                        "command": AgentGuidanceInstaller.sessionStartHookCommand(cliExecutablePath: cliCommand),
                        "timeout": 10,
                    ]],
                ]]],
            ])),
            File(path: "\(pluginName)/skills/\(AgentGuidanceIdentity.skillName)/SKILL.md", data: skill),
        ]
    }

    public static func jsonData(_ object: Any) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(0x0A)
        return data
    }

    public static func publicFiles(version: String, skill: Data) throws -> [File] {
        try files(
            pluginName: publicPluginName,
            cliCommandName: publicCLICommand,
            cliCommand: publicCLICommand,
            version: version,
            skill: skill,
            marketplace: Marketplace(
                name: publicMarketplaceName,
                description: "Batty's Claude Code plugin: the batty-cli skill, the batty mcp server and a SessionStart hook.",
                owner: ["name": "Batty", "url": "https://batty.sstools.co"],
                entryCarriesVersion: false
            )
        )
    }

    public static var marketplaceCommands: [String] {
        ["/plugin marketplace add \(publicRepository)", "/plugin install \(publicPluginName)@\(publicMarketplaceName)"]
    }

    public static func publicReadme(version: String) -> String {
        """
        # Batty plugins

        The Claude Code plugin for [Batty](https://batty.sstools.co), the macOS terminal multiplexer. \
        It adds the `batty-cli` skill, the `batty mcp` server and a SessionStart hook that tells Claude Code \
        which Batty Pane it is running in.

        The plugin runs `batty` from your `PATH`. Install the command first: Batty → Settings → Advanced → \
        Command Line and AI Agents → Install CLI.

        In Claude Code:

        ```
        \(marketplaceCommands.joined(separator: "\n"))
        ```

        `batty agent install` sets up the same plugin from the app. Use one or the other, not both: \
        both would register the `batty` MCP server and hook twice.

        Generated from Batty \(version) by `tools/build-agent-downloads.py`; don't edit by hand.

        """
    }
}
