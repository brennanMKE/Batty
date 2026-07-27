// NotifyCommand.swift

import ArgumentParser
import BattyCLICore
import BattyXPCCore
import Foundation

/// `batty notify` — the agent loop's terminal step (#0257's Tier 1 `notify`
/// verb, built by #0284): posts an entry into the Bell Feed so a
/// long-running agent can tell the user "done" or "I need input" without
/// them watching that pane.
///
/// A bare app-level verb, not a noun subcommand, like `open` in #0257's
/// table — it hangs off `BattyCLI.subcommands` directly rather than under a
/// noun, since there is no sub-object (`notify what?`) to disambiguate.
///
/// Goes over XPC request/reply, not the one-way `batty://` scheme, for the
/// same reason `pane split`/`pane close` do: `notify` is the *terminal*
/// step of the agent loop, so "the agent believes the user was told, but
/// nothing happened" is the least recoverable silent failure in the whole
/// chain. `batty://`'s one advantage over XPC — launching a not-yet-running
/// app — is worthless here: posting into the feed of an app that isn't
/// running is meaningless, so `notify` gains nothing from staying one-way.
///
/// Always resolves to a real tab (`--tab` flag → `BATTY_TAB_ID` env → the
/// app's focused tab) rather than accepting a placeholder/synthetic
/// identity: `BellFeedEntry` has no kind field distinguishing a CLI
/// notification from a real bell, and every consumer (`pathLabel(for:)`,
/// `jumpToBellEntry`, tab-close cleanup) assumes a live tab. Attributing to
/// one for real means click-to-jump, cleanup-on-close, and AI summarization
/// all work unmodified.
struct NotifyCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "notify",
        abstract: "Post a notification into the Bell Feed.",
        discussion: """
        Posts an entry into the Bell Feed attributed to the calling/target \
        tab — the same feed Bell events (BEL / OSC 9) land in, including \
        the macOS system notification, per-session mute, and AI \
        summarization pipeline. Requires a resolvable tab: an explicit \
        --tab, BATTY_TAB_ID (injected into every Batty pane at spawn), or \
        the app's currently focused tab.
        """,
        helpNames: .long
    )

    @Option(name: .long, help: "Notification title.")
    var title: String

    @Option(name: .long, help: "Notification body.")
    var body: String?

    @Flag(name: .long, help: "Request sound, subject to Settings → Notifications → \"Play sound\".")
    var sound = false

    @Option(name: .long, help: "Tab id to attribute the notification to. Falls back to BATTY_TAB_ID, then the focused tab, when omitted.")
    var tab: String?

    nonisolated func run() throws {
        guard !title.isEmpty else {
            fputs("batty: --title must not be empty\n", stderr)
            throw ExitCode.failure
        }
        let targetTabID = try resolveTargetTabID(flag: tab)
        let bodyOverride = body.flatMap { $0.isEmpty ? nil : $0 }

        switch AppConnectDance.resolveEndpoint() {
        case .failure(.brokerUnreachable):
            fputs("batty: broker unreachable\n", stderr)
            throw ExitCode(XPCExitCode.brokerUnreachable)
        case .failure(.appUnavailable):
            fputs("batty: app unavailable\n", stderr)
            throw ExitCode(XPCExitCode.appUnavailable)
        case .success(let endpoint):
            switch AppServiceClient.notify(endpoint: endpoint, tabID: targetTabID, title: title, body: bodyOverride, sound: sound, timeout: 3.0) {
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

    /// `--tab` resolution: explicit flag → `BATTY_TAB_ID` env → `nil` (let
    /// the app resolve the focused tab). Same chain shape as `PaneCommand
    /// .swift`'s `resolveTargetPaneID`, one tier further down (tab, not
    /// pane) — a `BellFeedEntry` needs a real tab, not merely a real pane.
    private nonisolated func resolveTargetTabID(flag: String?) throws -> UUID? {
        switch BattyTargetResolver.resolve(flag: flag, environmentKey: .tabID) {
        case let .success(id):
            return id
        case let .failure(.malformedFlag(raw)):
            fputs("batty: invalid --tab id: \(raw)\n", stderr)
            throw ExitCode.failure
        }
    }
}
