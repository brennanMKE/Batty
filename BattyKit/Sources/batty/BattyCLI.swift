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
        subcommands: [NewSessionCommand.self, PingCommand.self, StatusCommand.self, ListCommand.self, SessionNounCommand.self],
        defaultSubcommand: NewSessionCommand.self
    )
}

/// The CLI's original (and still default) behavior: `batty <path>` and bare
/// `batty` create a session. Named `new`, not `open` — `issues/0257.md`
/// pins `batty open` to mean "activate/foreground Batty" and session
/// creation to `batty session new [<path>]` in the eventual noun/verb
/// grammar; `open` would collide with that reservation, `new` doesn't (the
/// CLI has never shipped in a tagged release, so renaming here costs
/// nothing). ArgumentParser's `defaultSubcommand` still makes the bare form
/// work unchanged. One edge case this introduces: a directory literally
/// named the same as another subcommand (`new`, `ping`, `status`, `list`,
/// or `session`) now needs `batty new new` / `batty new ping` / etc. to
/// disambiguate; `batty ping` used to just try (and fail to resolve) a
/// relative path called "ping".
struct NewSessionCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "new",
        abstract: "Create a new Batty session rooted at a directory."
    )

    @Argument(help: "Directory for the new session. Defaults to the current directory.")
    var path: String = "."

    nonisolated func run() throws {
        let resolved = try resolvePath(path)
        guard let url = SessionURLBuilder.buildURL(absolutePath: resolved) else {
            fputs("batty: failed to build IPC URL for path: \(resolved)\n", stderr)
            throw ExitCode.failure
        }
        try openURL(url)
    }
}
