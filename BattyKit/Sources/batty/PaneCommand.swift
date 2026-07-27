// PaneCommand.swift

import ArgumentParser
import BattyCLICore
import BattyXPCCore
import Foundation

/// `batty pane` — the noun #0257's eventual grammar (`pane hide`, `show`,
/// `focus`, `zoom`, `close`) will grow siblings under. Only `split` (#0282)
/// exists today.
struct PaneNounCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pane",
        abstract: "Split or otherwise control a Batty pane.",
        subcommands: [PaneSplitCommand.self]
    )
}

/// `batty pane split` — the first mutating verb carried over XPC
/// request/reply rather than the one-way `batty://` scheme (#0257's
/// 2026-07-26 transport amendment), so a stale/unknown `--pane` id is
/// visible to the caller (exit `4`) instead of silently swallowed.
///
/// The noun stays `pane`, deliberately: splitting subdivides a *region* of
/// the session's split tree — never a terminal — so `surface split` (even
/// though `surface` is an accepted alias for `tab`) would be a category
/// error.
struct PaneSplitCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "split",
        abstract: "Split the calling/target pane, printing the new pane's id.",
        // Frees `-h` for `--horizontal` below; `--help` (long form only)
        // still works.
        helpNames: .long
    )

    /// Mutually exclusive by construction (`EnumerableFlag` + `@Flag`'s
    /// default `exclusivity: .exclusive`) — `-h -v` together is a parse
    /// error. Defaults to `.horizontal` when neither is given, per this
    /// issue's refinement of #0257 (which specified the flags but pinned no
    /// default).
    @Flag(help: "Split direction. Defaults to horizontal.")
    var direction: SplitDirectionFlag = .horizontal

    @Option(name: [.customShort("c"), .long], help: "Run this command in the new pane instead of the default shell.")
    var command: String?

    @Option(name: .long, help: "Pane id to split. Falls back to BATTY_PANE_ID, then the focused pane, when omitted.")
    var pane: String?

    nonisolated func run() throws {
        let targetPaneID = try resolvePaneID()
        let wireDirection: TopologySplitDirection = direction == .vertical ? .vertical : .horizontal
        let commandOverride = command.flatMap { $0.isEmpty ? nil : $0 }

        switch AppConnectDance.resolveEndpoint() {
        case .failure(.brokerUnreachable):
            fputs("batty: broker unreachable\n", stderr)
            throw ExitCode(XPCExitCode.brokerUnreachable)
        case .failure(.appUnavailable):
            fputs("batty: app unavailable\n", stderr)
            throw ExitCode(XPCExitCode.appUnavailable)
        case .success(let endpoint):
            switch AppServiceClient.paneSplit(endpoint: endpoint, paneID: targetPaneID, direction: wireDirection, command: commandOverride, timeout: 3.0) {
            case .success(let reply):
                print(reply.paneID)
            case .unreachable:
                fputs("batty: app unavailable\n", stderr)
                throw ExitCode(XPCExitCode.appUnavailable)
            case .requestFailed(let message):
                fputs("batty: request failed — \(message)\n", stderr)
                throw ExitCode(XPCExitCode.requestFailed)
            case .appTerminated:
                fputs("batty: app terminated\n", stderr)
                throw ExitCode(XPCExitCode.sessionTerminated)
            }
        }
    }

    /// `--pane` flag → `BATTY_PANE_ID` env → `nil`, meaning "let the app
    /// resolve the focused pane."
    private func resolvePaneID() throws -> UUID? {
        switch BattyTargetResolver.resolve(flag: pane, environmentKey: .paneID) {
        case let .success(id):
            return id
        case let .failure(.malformedFlag(raw)):
            fputs("batty: invalid --pane id: \(raw)\n", stderr)
            throw ExitCode.failure
        }
    }
}

/// `-h`/`-v` as an `ArgumentParser` `EnumerableFlag` — see
/// `PaneSplitCommand.direction`'s doc for the default/exclusivity behavior.
/// `nonisolated`: read from `PaneSplitCommand.run()`, itself `nonisolated`
/// per `ArgumentParser`'s own requirement, so this package's
/// `.defaultIsolation(MainActor.self)` would otherwise main-actor-isolate
/// its synthesized `Equatable`/`CaseIterable` conformances — same discipline
/// as `BattyContextEnvironmentKey` (`BattyCLICore`).
nonisolated enum SplitDirectionFlag: EnumerableFlag {
    case horizontal
    case vertical

    static func name(for value: Self) -> NameSpecification {
        switch value {
        case .horizontal: return [.customShort("h"), .long]
        case .vertical: return [.customShort("v"), .long]
        }
    }
}
