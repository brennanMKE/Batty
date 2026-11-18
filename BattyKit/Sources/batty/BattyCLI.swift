// BattyCLI.swift

import ArgumentParser
import BattyCLICore
import BattyXPCCore
import Foundation

@main
struct BattyCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "batty",
        abstract: "Control Batty from the command line.",
        discussion: "Bare `batty` and `batty <path>` are shorthand for `batty new <path>`.",
        version: resolveAppVersion(),
        subcommands: subcommands(for: .current),
        defaultSubcommand: NewSessionCommand.self
    )

    /// The CLI's variant is fixed at compile time, so production only passes
    /// `.current`; taking the flags lets tests build both trees. With
    /// `agentIntegration` off, `mcp` and `agent` are not in the tree at all,
    /// so `--help`, `batty capabilities` and the MCP tool list never mention them.
    static func subcommands(for flags: FeatureFlags) -> [ParsableCommand.Type] {
        var commands: [ParsableCommand.Type] = [
            NewSessionCommand.self, PingCommand.self, StatusCommand.self, ListCommand.self,
            SessionNounCommand.self, PaneNounCommand.self, TabNounCommand.self, ProjectNounCommand.self,
            IDCommand.self, NotifyCommand.self,
        ]
        if flags.agentIntegration {
            commands += [MCPCommand.self, AgentNounCommand.self]
        }
        commands.append(CapabilitiesCommand.self)
        return commands
    }
}
