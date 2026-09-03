// TabCommand.swift

import ArgumentParser
import BattyCLICore
import BattyXPCCore
import Foundation

/// `batty tab` — new for #0381, which needs exactly one subcommand
/// (`focus`) and deliberately builds no others. #0257's "a filed ticket
/// reads as scheduled work" rule (restated by #0382) means `tab new`,
/// `tab rename`, and `tab close` stay unbuilt until they're each actually
/// scheduled, not stubbed out here alongside `focus`.
struct TabNounCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tab",
        abstract: "Focus or otherwise control a Batty tab.",
        subcommands: [TabFocusCommand.self]
    )
}

/// `batty tab focus` — #0381: one of the three "show the human what I did"
/// verbs, over XPC request/reply following #0282's mutation-verb pattern.
///
/// **`surface` is an accepted alias for `tab`** (#0257's 2026-07-27
/// terminology amendment), but this command is registered only under the
/// `tab` noun — `surface` is an alias for the noun in conversation and
/// documentation, not a second `ParsableCommand` subtree to keep in sync.
///
/// Selects the target tab if it isn't already selected, and implies
/// focusing its containing pane — the terminology amendment's pinned
/// semantics, distinct from `pane focus`, which never re-selects tabs.
/// **Activating**, like `session focus`/`pane focus`: selects the tab's
/// owning session and brings its window forward, the CLI's one sanctioned
/// exception to "a mutation aimed at a background session must not switch
/// the active session."
struct TabFocusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "focus",
        abstract: "Focus a tab by id, selecting it, its pane, and its session, and activating its window.",
        discussion: """
        Selects the target tab if it isn't already its pane's active tab, \
        focuses that pane, selects its owning session, and brings the \
        session's window forward. Unlike `pane focus`, this verb changes \
        which tab is selected — that's the whole point of focusing a tab \
        rather than a pane. Only id-based targeting is implemented; \
        index-based targeting (`<n>`) is not.
        """,
        helpNames: .long
    )

    @Argument(help: "Tab id to focus. Falls back to BATTY_TAB_ID, then the focused tab, when omitted.")
    var id: String?

    nonisolated func run() throws {
        let targetTabID = try resolveTargetTabID(flag: id)

        switch AppConnectDance.resolveEndpoint() {
        case .failure(.brokerUnreachable):
            fputs("batty: broker unreachable\n", stderr)
            throw ExitCode(XPCExitCode.brokerUnreachable)
        case .failure(.appUnavailable):
            fputs("batty: app unavailable\n", stderr)
            throw ExitCode(XPCExitCode.appUnavailable)
        case .failure(.appRunningUnregistered):
            fputs("batty: Batty is running but isn't responding to the broker — try relaunching it\n", stderr)
            throw ExitCode(XPCExitCode.appRunningUnregistered)
        case .failure(.appBundleUnresolved(let message)):
            fputs("batty: \(message)\n", stderr)
            throw ExitCode(XPCExitCode.appBundleUnresolved)
        case .success(let endpoint):
            switch AppServiceClient.tabFocus(endpoint: endpoint, tabID: targetTabID, timeout: 3.0) {
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

    /// `<id>` argument → `BATTY_TAB_ID` env → `nil` (let the app resolve
    /// the focused tab). Same chain shape as `NotifyCommand`'s
    /// `resolveTargetTabID`, driven by a positional argument rather than a
    /// `--tab` flag — see `PaneFocusCommand`'s doc for why focus verbs use
    /// a positional id.
    private nonisolated func resolveTargetTabID(flag: String?) throws -> UUID? {
        switch BattyTargetResolver.resolve(flag: flag, environmentKey: .tabID) {
        case let .success(id):
            return id
        case let .failure(.malformedFlag(raw)):
            fputs("batty: invalid tab id: \(raw)\n", stderr)
            throw ExitCode.failure
        }
    }
}
