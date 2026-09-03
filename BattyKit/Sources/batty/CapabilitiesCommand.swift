// CapabilitiesCommand.swift

import ArgumentParser
import BattyXPCCore
import Foundation

/// `batty capabilities` — a static, compiled-in description of this build's
/// verb roster and exit-code vocabulary (#0384), so an agent facing an
/// installed `batty` can discover what it supports instead of guessing or
/// tripping a verb to see if it errors.
///
/// **Pinned decision (#0384): no XPC round trip.** The CLI and the app ship
/// in the same bundle, so the CLI already knows its own surface at compile
/// time; asking the app would add a failure mode (broker unreachable) to a
/// command whose entire job is to work *before* anything else is known to.
/// This must succeed with exit `0` even when Batty is not running at all —
/// the opposite of `status`, whose job is reporting whether the app answers.
struct CapabilitiesCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "capabilities",
        abstract: "Report the verbs and exit-code vocabulary this batty build supports."
    )

    @Flag(name: .long, help: "Emit JSON instead of a plain-text summary.")
    var json = false

    nonisolated func run() throws {
        let payload = Self.buildPayload()
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            guard let data = try? encoder.encode(payload), let text = String(data: data, encoding: .utf8) else {
                fputs("batty: failed to encode capabilities as JSON\n", stderr)
                throw ExitCode.failure
            }
            print(text)
        } else {
            Self.printPlainText(payload)
        }
    }

    static func buildPayload() -> CapabilitiesPayload {
        CapabilitiesPayload(
            cliVersion: resolveAppVersion(),
            verbs: Self.verbs(),
            exitCodes: CapabilitiesPayload.standardExitCodes(
                success: ExitCode.success.rawValue,
                failure: ExitCode.failure.rawValue,
                validationFailure: ExitCode.validationFailure.rawValue
            )
        )
    }

    /// Walks `BattyCLI`'s own subcommand tree rather than hand-listing verb
    /// names, so a verb wired into `BattyCLI.configuration.subcommands`
    /// later is reported automatically — the pinned decision in #0384: "a
    /// verb added later cannot silently go unreported." A noun with
    /// children (`session`, `pane`, `tab`) is never itself directly
    /// invocable, so only its leaves are reported (`session info`,
    /// `session focus`, `session close`, `pane split`, `pane close`, `pane
    /// focus`, `pane hide`, `pane show`, `tab focus`), joined with the noun
    /// as `"pane split"`. `XPCVerb.watch` is
    /// correctly absent from this list: it has no entry anywhere in
    /// `BattyCLI`'s tree because #0145 never gave it a CLI command.
    static func verbs() -> [CapabilitiesVerbPayload] {
        BattyCLI.configuration.subcommands.flatMap { collectVerbs(from: $0, prefix: []) }
    }

    private static func collectVerbs(from type: ParsableCommand.Type, prefix: [String]) -> [CapabilitiesVerbPayload] {
        let config = type.configuration
        let name = config.commandName ?? String(describing: type)
        let path = prefix + [name]
        guard !config.subcommands.isEmpty else {
            return [CapabilitiesVerbPayload(name: path.joined(separator: " "), abstract: config.abstract, aliases: config.aliases)]
        }
        return config.subcommands.flatMap { collectVerbs(from: $0, prefix: path) }
    }

    private static func printPlainText(_ payload: CapabilitiesPayload) {
        print("batty \(payload.cliVersion) capabilities")
        print("verbs:")
        for verb in payload.verbs {
            let aliasText = verb.aliases.isEmpty ? "" : " (alias: \(verb.aliases.joined(separator: ", ")))"
            print("  \(verb.name)\(aliasText) — \(verb.abstract)")
        }
        print("exit codes:")
        for exitCode in payload.exitCodes {
            print("  \(exitCode.code) — \(exitCode.meaning)")
        }
    }
}
