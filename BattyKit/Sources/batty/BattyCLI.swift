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

    /// The CLI is a bare Mach-O whose variant is fixed at compile time, so
    /// `.current` is the only value production passes. Taking the flags as a
    /// parameter lets tests build both trees. With `projects` off the
    /// `project` noun is not in the tree at all, so `--help` and `batty
    /// capabilities` never mention it.
    static func subcommands(for flags: FeatureFlags) -> [ParsableCommand.Type] {
        var commands: [ParsableCommand.Type] = [NewSessionCommand.self, PingCommand.self, StatusCommand.self, ListCommand.self, SessionNounCommand.self, PaneNounCommand.self, TabNounCommand.self]
        if flags.projects {
            commands.append(ProjectNounCommand.self)
        }
        commands += [IDCommand.self, NotifyCommand.self, CapabilitiesCommand.self]
        return commands
    }
}
