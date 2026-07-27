// IDCommand.swift

import ArgumentParser
import BattyCLICore
import Foundation

/// `batty id` — print this pane's session/pane/tab identity from
/// environment alone, no app round-trip (#0257 Foundation §3, built by
/// #0281). `id` is the primary command name; `whoami` is a registered
/// alias (`aliases:` below — ArgumentParser lists it in `batty --help`
/// automatically). All prose and output still say `batty id`, per the
/// user's 2026-07-26 decision (see `docs/batty-cli-design.md`).
struct IDCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "id",
        abstract: "Print this pane's session/pane/tab id from environment.",
        aliases: ["whoami"]
    )

    @Flag(name: .long, help: "Emit JSON instead of a plain-text summary.")
    var json = false

    nonisolated func run() throws {
        switch BattyIdentityContext.resolve() {
        case let .success(context):
            if json {
                try Self.printJSON(context)
            } else {
                Self.printPlainText(context)
            }
        case let .failure(error):
            fputs("batty: \(error.description)\n", stderr)
            throw ExitCode.failure
        }
    }

    private static func printJSON(_ context: BattyIdentityContext) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(context), let text = String(data: data, encoding: .utf8) else {
            fputs("batty: failed to encode identity as JSON\n", stderr)
            throw ExitCode.failure
        }
        print(text)
    }

    private static func printPlainText(_ context: BattyIdentityContext) {
        print("session \(context.sessionID)")
        print("pane \(context.paneID)")
        print("tab \(context.tabID)")
    }
}
