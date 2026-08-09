// PaneCommand.swift

import ArgumentParser
import BattyCLICore
import BattyXPCCore
import Foundation

/// `batty pane` — the noun #0257's eventual grammar (`pane hide`, `show`,
/// `focus`, `zoom`) will grow siblings under. `split` (#0282) and `close`
/// (#0283) exist today.
struct PaneNounCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pane",
        abstract: "Split, close, or otherwise control a Batty pane.",
        subcommands: [PaneSplitCommand.self, PaneCloseCommand.self]
    )
}

/// Shared `--pane` resolution for every `pane` subcommand: explicit flag →
/// `BATTY_PANE_ID` env → `nil` (let the app resolve the focused pane).
/// `nonisolated` — called from each subcommand's `nonisolated func run()`.
private nonisolated func resolveTargetPaneID(flag: String?) throws -> UUID? {
    switch BattyTargetResolver.resolve(flag: flag, environmentKey: .paneID) {
    case let .success(id):
        return id
    case let .failure(.malformedFlag(raw)):
        fputs("batty: invalid --pane id: \(raw)\n", stderr)
        throw ExitCode.failure
    }
}

/// Resolves `pane split --view <kind>` client-side. `nil` (flag omitted)
/// means "no explicit kind" — the wire/model layer's own default is
/// `.terminal` (#0315's directive: omitting `--view` must keep every
/// existing invocation producing a terminal pane unchanged). An unknown
/// kind string fails fast here with exit `1`, listing the valid set,
/// rather than round-tripping to the app only to fail there.
private nonisolated func resolveViewKind(flag: String?) throws -> PaneContentKind? {
    guard let flag else { return nil }
    guard let kind = PaneContentKind(rawValue: flag) else {
        let valid = PaneContentKind.allCases.map(\.rawValue).joined(separator: ", ")
        fputs("batty: invalid --view kind: \(flag) (expected one of: \(valid))\n", stderr)
        throw ExitCode.failure
    }
    return kind
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

    /// #0315. Omitted means Terminal — every existing `pane split`
    /// invocation keeps producing exactly the terminal pane it always did.
    /// Validated client-side against `PaneContentKind`'s known raw values
    /// (the same string used as the Codable/topology spelling,
    /// `docs/pane-kinds.md` §5) so an unknown kind fails fast with exit `1`
    /// rather than reaching the app.
    @Option(name: .long, help: "Pane content kind for the new pane. Defaults to terminal. One of: \(PaneContentKind.allCases.map(\.rawValue).joined(separator: ", ")).")
    var view: String?

    nonisolated func run() throws {
        let targetPaneID = try resolveTargetPaneID(flag: pane)
        let wireDirection: TopologySplitDirection = direction == .vertical ? .vertical : .horizontal
        let commandOverride = command.flatMap { $0.isEmpty ? nil : $0 }
        let resolvedKind = try resolveViewKind(flag: view)
        // `-c/--command` presumes a shell; a non-terminal pane has none —
        // reject the combination client-side rather than silently dropping
        // `-c` (#0315 review round 1, non-blocking item).
        if let resolvedKind, resolvedKind != .terminal, commandOverride != nil {
            fputs("batty: --command is not valid with --view \(resolvedKind.rawValue) (non-terminal panes have no shell)\n", stderr)
            throw ExitCode.failure
        }

        switch AppConnectDance.resolveEndpoint() {
        case .failure(.brokerUnreachable):
            fputs("batty: broker unreachable\n", stderr)
            throw ExitCode(XPCExitCode.brokerUnreachable)
        case .failure(.appUnavailable):
            fputs("batty: app unavailable\n", stderr)
            throw ExitCode(XPCExitCode.appUnavailable)
        case .success(let endpoint):
            switch AppServiceClient.paneSplit(endpoint: endpoint, paneID: targetPaneID, direction: wireDirection, command: commandOverride, kind: resolvedKind, timeout: 3.0) {
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
}

/// `batty pane close` — the second mutating verb carried over XPC
/// request/reply (#0283, following #0282's pattern), so a stale/unknown
/// `--pane` id, a pane XPC has no UI to confirm closing, or a refusal to
/// close the app's last pane are all visible to the caller (exit `4`)
/// instead of silently swallowed.
///
/// **Not `tab close`:** this ends every Tab's Terminal Session in the pane —
/// not just the active one — and collapses the pane's region into its
/// sibling. Closing exactly one tab, removing the pane only when it was
/// that tab's last, is a different (smaller, unfiled) operation; reach for
/// that one instead of this one if that's what's wanted.
struct PaneCloseCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "close",
        abstract: "Close every tab in the calling/target pane and remove it from the split.",
        discussion: """
        Ends every Tab's Terminal Session in the pane, not just the active \
        one, and collapses the pane's region into its sibling subtree. This \
        is pane-level close, not tab-level: closing a single tab (removing \
        the pane only if that tab was its last) is a different, smaller \
        operation.
        """,
        helpNames: .long
    )

    @Option(name: .long, help: "Pane id to close. Falls back to BATTY_PANE_ID, then the focused pane, when omitted.")
    var pane: String?

    nonisolated func run() throws {
        let targetPaneID = try resolveTargetPaneID(flag: pane)

        switch AppConnectDance.resolveEndpoint() {
        case .failure(.brokerUnreachable):
            fputs("batty: broker unreachable\n", stderr)
            throw ExitCode(XPCExitCode.brokerUnreachable)
        case .failure(.appUnavailable):
            fputs("batty: app unavailable\n", stderr)
            throw ExitCode(XPCExitCode.appUnavailable)
        case .success(let endpoint):
            switch AppServiceClient.paneClose(endpoint: endpoint, paneID: targetPaneID, timeout: 3.0) {
            case .success:
                break
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
