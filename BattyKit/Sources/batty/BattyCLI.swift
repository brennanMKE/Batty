// BattyCLI.swift

import ArgumentParser
import BattyCLICore
import Foundation

@main
struct BattyCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "batty",
        abstract: "Control Batty from the command line.",
        discussion: "Bare `batty` and `batty <path>` are shorthand for `batty new <path>`.",
        version: resolveAppVersion(),
        subcommands: [NewSessionCommand.self, PingCommand.self, StatusCommand.self, ListCommand.self, SessionNounCommand.self, PaneNounCommand.self, TabNounCommand.self, IDCommand.self, NotifyCommand.self, CapabilitiesCommand.self],
        defaultSubcommand: NewSessionCommand.self
    )
}
