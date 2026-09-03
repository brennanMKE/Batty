// PaneCommand.swift

import ArgumentParser
import BattyCLICore
import BattyXPCCore
import Foundation

/// `batty pane` — the noun #0257's eventual grammar (`pane zoom`) will grow
/// siblings under. `split` (#0282), `close` (#0283), `focus` (#0381), and
/// `hide`/`show` (#0382) exist today.
struct PaneNounCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pane",
        abstract: "Split, close, or otherwise control a Batty pane.",
        subcommands: [PaneSplitCommand.self, PaneCloseCommand.self, PaneFocusCommand.self, PaneHideCommand.self, PaneShowCommand.self]
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

    /// `#0305`: pins a `.processStatus` pane to a literal pid (mode A,
    /// `docs/design/process-status-view.md` §2) instead of the default
    /// mode B (follow the split-source pane's active Tab's foreground
    /// process). Rejected client-side for any other `--view` kind. Carried
    /// over the wire in `PaneSplitRequest.viewOptions["pid"]` — #0304's
    /// generic per-kind option bag, not a bespoke field of its own.
    @Option(name: .long, help: "Pin a process-status pane to this pid instead of following a terminal's foreground process. Only valid with --view process-status.")
    var pid: Int32?

    /// #0304. The directory a `--view git-status` pane monitors
    /// (`docs/design/git-status-view.md` §1's resolution order — this flag
    /// first, else the target pane's own working directory, else `$HOME`).
    /// Resolved to an absolute path here, against the CLI process's own
    /// cwd, before the XPC call — no relative-path resolution happens
    /// app-side, the same discipline `BattyTargetResolver` already applies
    /// to ids. Carried over the wire in
    /// `PaneSplitRequest.viewOptions["path"]`.
    @Option(name: .long, help: "Directory for the new pane to monitor (only valid with --view git-status). Resolved to an absolute path.")
    var path: String?

    /// #0383. Find-or-create: if the target Session already has a visible
    /// Pane of the requested `--view` kind, prints *that* Pane's id and
    /// creates nothing. `viewOptions` differences (a different `--path` or
    /// `--pid`) do not defeat the match — a matching-kind Pane is returned
    /// as-is even if pointed elsewhere; close it first if it needs to be
    /// re-pointed. Only meaningful with a non-terminal `--view <kind>` —
    /// rejected against an omitted `--view`/`--view terminal`, the same
    /// way `--pid`/`--path` are rejected against the wrong kinds above.
    @Flag(name: .long, help: "With --view <kind>, print the id of an existing visible pane of that kind instead of creating one. viewOptions differences (--path/--pid) do not defeat the match. Requires a non-terminal --view.")
    var unique: Bool = false

    nonisolated func run() throws {
        let targetPaneID = try resolveTargetPaneID(flag: pane)
        let wireDirection: TopologySplitDirection = direction == .vertical ? .vertical : .horizontal
        let commandOverride = command.flatMap { $0.isEmpty ? nil : $0 }
        let resolvedKind = try resolveViewKind(flag: view)
        if unique, resolvedKind == nil || resolvedKind == .terminal {
            fputs("batty: --unique requires a non-terminal --view <kind> (there is no sensible \"the terminal pane\" to find)\n", stderr)
            throw ExitCode.failure
        }
        // `-c/--command` presumes a shell; a non-terminal pane has none —
        // reject the combination client-side rather than silently dropping
        // `-c` (#0315 review round 1, non-blocking item).
        if let resolvedKind, resolvedKind != .terminal, commandOverride != nil {
            fputs("batty: --command is not valid with --view \(resolvedKind.rawValue) (non-terminal panes have no shell)\n", stderr)
            throw ExitCode.failure
        }
        if pid != nil, resolvedKind != .processStatus {
            fputs("batty: --pid is only valid with --view process-status\n", stderr)
            throw ExitCode.failure
        }
        // Review round 1 ("keep it" caveat): a non-positive pid is never
        // a real process id and previously surfaced as a confusing
        // permission-denied state at the app layer instead of a CLI
        // parse error — reject it here, before any XPC round trip.
        if let pid, pid <= 0 {
            fputs("batty: --pid must be a positive integer, got \(pid)\n", stderr)
            throw ExitCode.failure
        }
        // `--path` is `.gitStatus`-specific, not "any non-terminal kind" —
        // review round 1, D3: the original check only rejected `--path`
        // for terminal/omitted `--view`, so it was silently accepted (and
        // silently dropped, since nothing read it) for every *other*
        // non-terminal kind too (e.g. `--view process-status --path ...`).
        // Each kind's own option key is validated against that kind
        // specifically, mirroring `--pid`/`.processStatus` above, not
        // against "is this a non-terminal pane at all."
        if path != nil, resolvedKind != .gitStatus {
            let kindDescription = resolvedKind?.rawValue ?? "terminal"
            fputs("batty: --path is not valid with --view \(kindDescription) (only git-status accepts --path)\n", stderr)
            throw ExitCode.failure
        }
        let resolvedPath = path.map { URL(fileURLWithPath: $0).path }
        // Built incrementally, one key per kind-specific flag, so a future
        // flag is one more `if let` here rather than a restructuring of
        // this one — see the same reasoning on `viewOptions`'s doc comment
        // in `PaneSplitPayload.swift`.
        var viewOptions: [String: String] = [:]
        if let resolvedPath {
            viewOptions["path"] = resolvedPath
        }
        if let pid {
            viewOptions["pid"] = String(pid)
        }
        let wireViewOptions: [String: String]? = viewOptions.isEmpty ? nil : viewOptions

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
            let wireUnique: Bool? = unique ? true : nil
            switch AppServiceClient.paneSplit(endpoint: endpoint, paneID: targetPaneID, direction: wireDirection, command: commandOverride, kind: resolvedKind, viewOptions: wireViewOptions, unique: wireUnique, timeout: 3.0) {
            case .success(let reply):
                // No `batty: ` prefix (N1, #0383 review round 1): every
                // other `batty: ` line in this file sits on a path that
                // throws non-zero immediately after, so a caller treating
                // that prefix as a failure signal would misread this
                // exit-0 line. This is the only channel through which a
                // shell caller learns found-vs-created at all — `pane
                // split` has no `--json` and stdout stays a bare id.
                if reply.created == false {
                    fputs("--unique matched an existing pane; nothing created\n", stderr)
                } else if unique, reply.created == nil {
                    // `created` is only ever `nil` from an app build that
                    // predates #0383 entirely (a new app always populates
                    // it on both branches) — the running Batty silently
                    // ignored `--unique` and created unconditionally.
                    fputs("--unique is not supported by the running Batty; a new pane may have been created\n", stderr)
                }
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
        case .failure(.appRunningUnregistered):
            fputs("batty: Batty is running but isn't responding to the broker — try relaunching it\n", stderr)
            throw ExitCode(XPCExitCode.appRunningUnregistered)
        case .failure(.appBundleUnresolved(let message)):
            fputs("batty: \(message)\n", stderr)
            throw ExitCode(XPCExitCode.appBundleUnresolved)
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

/// `batty pane focus` — #0381: one of the three "show the human what I
/// did" verbs, over XPC request/reply following #0282's mutation-verb
/// pattern.
///
/// **Id-based targeting only.** #0257's table also lists directional
/// targeting (`up`/`down`/`left`/`right`), but that's deferred: id-based
/// targeting is what an agent needs (the id comes straight from `pane
/// split`, `batty new`, or `batty list --json`), and directional targeting
/// drags in split-tree geometry work with no agent-facing payoff.
///
/// **Activating**, unlike `pane split`/`pane close`: #0257's 2026-07-27
/// terminology amendment names the `focus` verbs as the CLI's one
/// sanctioned exception to "a mutation aimed at a background session must
/// not switch the active session." Focusing a pane in a non-selected
/// session selects that session and brings its window forward — but the
/// target pane's own selected tab is left unchanged; moving focus between
/// panes must never re-select tabs.
struct PaneFocusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "focus",
        abstract: "Focus a pane by id, selecting its session and activating its window.",
        discussion: """
        Focuses the target pane, selects its owning session, and brings its \
        window forward. The pane's own active tab is left unchanged — \
        moving focus between panes never re-selects tabs. Directional \
        targeting (up/down/left/right) is deferred; only id-based targeting \
        is implemented.
        """,
        helpNames: .long
    )

    @Argument(help: "Pane id to focus. Falls back to BATTY_PANE_ID, then the focused pane, when omitted.")
    var id: String?

    nonisolated func run() throws {
        let targetPaneID = try Self.resolveTargetPaneID(flag: id)

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
            switch AppServiceClient.paneFocus(endpoint: endpoint, paneID: targetPaneID, timeout: 3.0) {
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

    /// `<id>` argument → `BATTY_PANE_ID` env → `nil` (let the app resolve
    /// the focused pane). Deliberately its own resolver, not the free
    /// `resolveTargetPaneID(flag:)` above: that one's error text says
    /// "invalid --pane id," which is wrong here — this command's target is
    /// a positional `<id>` argument, not a `--pane` flag (see this type's
    /// doc for why focus verbs use a positional id).
    private nonisolated static func resolveTargetPaneID(flag: String?) throws -> UUID? {
        switch BattyTargetResolver.resolve(flag: flag, environmentKey: .paneID) {
        case let .success(id):
            return id
        case let .failure(.malformedFlag(raw)):
            fputs("batty: invalid pane id: \(raw)\n", stderr)
            throw ExitCode.failure
        }
    }
}

/// `batty pane hide` — #0382: reverses what `pane split`/`batty new` built,
/// over XPC request/reply following #0282's mutation-verb pattern so a
/// stale/unknown `--pane` id or a refusal (the pane is its session's last
/// visible one) is visible to the caller (exit `4`) instead of a silent
/// no-op.
///
/// **Idempotent**: hiding an already-hidden pane succeeds quietly (exit
/// `0`), matching `pane show`'s own idempotence — scripts that don't track
/// visibility state don't need to.
///
/// **Not activating**, unlike the `focus` verbs (#0381): hiding a
/// background Pane must not steal focus or switch the selected Session
/// (#0257).
struct PaneHideCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hide",
        abstract: "Hide a pane (the eye-toggle's CLI equivalent), leaving it in the split but out of view.",
        discussion: """
        Hides the calling/target pane, matching the sidebar's eye toggle. \
        Idempotent — hiding an already-hidden pane succeeds quietly. \
        Refused when the pane is its session's only visible pane (a \
        session must always have at least one visible pane). Does not \
        select the pane's session or activate the window.
        """,
        helpNames: .long
    )

    @Option(name: .long, help: "Pane id to hide. Falls back to BATTY_PANE_ID, then the focused pane, when omitted.")
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
        case .failure(.appRunningUnregistered):
            fputs("batty: Batty is running but isn't responding to the broker — try relaunching it\n", stderr)
            throw ExitCode(XPCExitCode.appRunningUnregistered)
        case .failure(.appBundleUnresolved(let message)):
            fputs("batty: \(message)\n", stderr)
            throw ExitCode(XPCExitCode.appBundleUnresolved)
        case .success(let endpoint):
            switch AppServiceClient.paneHide(endpoint: endpoint, paneID: targetPaneID, timeout: 3.0) {
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

/// `batty pane show` — #0382: the un-hide counterpart of `pane hide`, over
/// XPC request/reply following the same mutation-verb pattern.
///
/// **Requires an explicit id — no `BATTY_PANE_ID`/focused-pane fallback,
/// unlike every other targeted verb.** #0257 already recorded why: a
/// hidden pane has no shell a `batty` call could be running from, so there
/// is no "focused element" to fall back to. Ids come from `batty list
/// --json`, which flags hidden panes.
///
/// **Idempotent**: showing an already-visible pane succeeds quietly (exit
/// `0`). **Not activating**, unlike the `focus` verbs (#0381): showing a
/// background Pane must not steal focus or switch the selected Session
/// (#0257).
struct PaneShowCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show",
        abstract: "Show (un-hide) a pane by id, printing nothing on success.",
        discussion: """
        Un-hides the target pane, matching the sidebar's eye toggle. \
        Idempotent — showing an already-visible pane succeeds quietly. \
        Unlike every other targeted verb, this one requires an explicit id \
        and never falls back to BATTY_PANE_ID or the focused pane: a \
        hidden pane has no shell to run `batty` from. Find hidden pane ids \
        with `batty list --json`. Does not select the pane's session or \
        activate the window.
        """,
        helpNames: .long
    )

    // `valueName: "pane-id"` (review round 1, N7): the issue and both docs
    // pin the literal usage as `batty pane show <pane-id>`, distinguishing
    // this required id from `pane focus <id>`'s optional/fallback-eligible
    // one — left at ArgumentParser's default (`<id>`), the two looked
    // identical in `--help` despite meaning different things.
    @Argument(help: ArgumentHelp("Pane id to show. Required — no BATTY_PANE_ID/focused-pane fallback (a hidden pane has no shell to run batty from).", valueName: "pane-id"))
    var id: String

    nonisolated func run() throws {
        guard let targetPaneID = UUID(uuidString: id) else {
            fputs("batty: invalid pane id: \(id)\n", stderr)
            throw ExitCode.failure
        }

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
            switch AppServiceClient.paneShow(endpoint: endpoint, paneID: targetPaneID, timeout: 3.0) {
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
