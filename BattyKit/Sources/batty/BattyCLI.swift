// BattyCLI.swift

import ArgumentParser
import BattyKit
import Foundation

@main
struct BattyCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "batty",
        abstract: "Control Batty from the command line.",
        version: "0.1.0"
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
