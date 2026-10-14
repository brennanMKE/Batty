// XPCVerb.swift

/// Verb strings carried in `XPCRequest.verb` (`XPCMessages.swift`). A single
/// source of truth so the app-side dispatcher (`AppXPCService`) and every
/// CLI call site agree on the literal without repeating it.
public nonisolated enum XPCVerb {
    /// The first verb (#0271): returns `StatusPayload` as
    /// `XPCResponse.payload`.
    public static let status = "status"

    /// #0274: returns `TopologyPayload` (every window/session/pane/tab) as
    /// `XPCResponse.payload`. No request payload.
    public static let list = "list"

    /// #0274: returns a single `TopologySessionPayload` as
    /// `XPCResponse.payload`. Request payload is `SessionInfoRequest`
    /// (optional — a missing/undecodable request is treated the same as an
    /// explicit `sessionID: nil`).
    public static let sessionInfo = "sessionInfo"

    /// #0282: the first *mutating* XPC verb. Splits a pane, replying with
    /// `PaneSplitReply` (the new pane's id) as `XPCResponse.payload`.
    /// Request payload is `PaneSplitRequest`. An unknown/stale
    /// `PaneSplitRequest.paneID` is a failure reply (`ok: false`), which the
    /// CLI surfaces as exit `4` — the reason this verb is on XPC rather than
    /// the fire-and-forget `batty://` scheme.
    public static let paneSplit = "paneSplit"

    /// #0283: the second mutating XPC verb. Ends every Tab's Terminal
    /// Session in the target pane and removes its region from the split
    /// tree, replying with an empty `PaneCloseReply` on success as
    /// `XPCResponse.payload`. Request payload is `PaneCloseRequest`. A
    /// failure reply (`ok: false`) covers an unknown/stale
    /// `PaneCloseRequest.paneID`, a pane with a Tab that needs confirmation
    /// XPC has no UI to give, and a refusal to close the app's last
    /// remaining pane — the CLI surfaces all three as exit `4`.
    public static let paneClose = "paneClose"

    /// #0284: the third mutating XPC verb — the agent loop's terminal step.
    /// Posts a `BellFeedEntry` attributed to a real tab, replying with an
    /// empty `NotifyReply` on success as `XPCResponse.payload`. Request
    /// payload is `NotifyRequest`. A failure reply (`ok: false`) covers an
    /// unknown/stale `NotifyRequest.tabID` and "no tab to target" (neither
    /// an explicit id nor a resolvable focused tab) — the CLI surfaces both
    /// as exit `4`. Went to XPC rather than the fire-and-forget `batty://`
    /// scheme for the same reason as `paneSplit`/`paneClose`: "the agent
    /// believes the user was told, but nothing happened" is the least
    /// recoverable silent failure in the whole agent loop.
    public static let notify = "notify"

    /// #0381: the fourth mutating XPC verb. Selects the target session
    /// (the CLI's one sanctioned exception to "a mutation aimed at a
    /// background session must not switch the active session") and
    /// activates its window, replying with an empty `SessionFocusReply` on
    /// success as `XPCResponse.payload`. Request payload is
    /// `SessionFocusRequest`. A failure reply (`ok: false`) covers an
    /// unknown/stale `SessionFocusRequest.sessionID` and "no session to
    /// target" — the CLI surfaces both as exit `4`.
    public static let sessionFocus = "sessionFocus"

    /// #0381: the fifth mutating XPC verb. Focuses the target pane and
    /// selects its owning session/activates its window, but leaves the
    /// pane's selected tab unchanged (#0257's 2026-07-27 terminology
    /// amendment: `pane focus` never re-selects tabs). Replying with an
    /// empty `PaneFocusReply` on success as `XPCResponse.payload`. Request
    /// payload is `PaneFocusRequest`. A failure reply (`ok: false`) covers
    /// an unknown/stale `PaneFocusRequest.paneID` and "no pane to
    /// target" — the CLI surfaces both as exit `4`. Directional targeting
    /// (`up`/`down`/`left`/`right`) is deferred; only id-based targeting is
    /// implemented.
    public static let paneFocus = "paneFocus"

    /// #0381: the sixth mutating XPC verb. Selects the target tab (if not
    /// already selected) and implies focusing its containing pane — both
    /// activating per the same terminology amendment as `paneFocus`.
    /// Replies with an empty `TabFocusReply` on success as
    /// `XPCResponse.payload`. Request payload is `TabFocusRequest`. A
    /// failure reply (`ok: false`) covers an unknown/stale
    /// `TabFocusRequest.tabID` and "no tab to target" — the CLI surfaces
    /// both as exit `4`.
    public static let tabFocus = "tabFocus"

    /// #0382: the seventh mutating XPC verb. Ends every Tab's Terminal
    /// Session across the target session's panes and removes the session —
    /// reusing `AppStateStore.removeSession(id:)` for the mutation, wrapped
    /// with the same refusal shape `paneClose` already established one
    /// tier down. The Sidebar's own "Close" control reaches the same
    /// `WindowRuntime.removeSession(id:fromCli:)` mutation (via
    /// `requestRemoveSession`, gated the same way) and emits the same
    /// `session_destroyed` watch event (#0396) — the two paths differ only
    /// in refusal shape: this verb refuses outright with no UI to confirm
    /// through, the Sidebar raises a confirmation dialog instead. See
    /// `AppStateStore.closeSessionForXPC(id:)`'s doc for detail. Replies with
    /// an empty `SessionCloseReply` on success as `XPCResponse.payload`.
    /// Request payload is `SessionCloseRequest`. A failure reply (`ok:
    /// false`) covers an unknown/stale `SessionCloseRequest.sessionID`,
    /// "no session to target," a session with a Tab that needs
    /// confirmation XPC has no UI to give, and a refusal to close the
    /// app's last remaining session — the CLI surfaces all four as exit
    /// `4`. Does **not** add a `--force` flag (#0283's confirmation shape,
    /// applied here unchanged).
    public static let sessionClose = "sessionClose"

    /// #0382: the eighth mutating XPC verb. Hides the target pane —
    /// reusing `WindowRuntime.hidePane(id:)` (the eye-toggle's own entry
    /// point) for the mutation. Idempotent: hiding an already-hidden pane
    /// succeeds quietly. Replies with an empty `PaneHideReply` on success
    /// as `XPCResponse.payload`. Request payload is `PaneHideRequest`. A
    /// failure reply (`ok: false`) covers an unknown/stale
    /// `PaneHideRequest.paneID`, "no pane to target," and a refusal to
    /// hide a session's last visible pane (the ≥1-visible-pane invariant
    /// `hidePane(id:)` already enforces, made a visible failure over XPC
    /// instead of a silent no-op) — the CLI surfaces all three as exit
    /// `4`.
    public static let paneHide = "paneHide"

    /// #0382: the ninth mutating XPC verb. Shows (un-hides) the target
    /// pane — reusing `WindowRuntime.showPane(id:)` for the mutation.
    /// Idempotent: showing an already-visible pane succeeds quietly.
    /// **No fallback target**, unlike every other targeted verb: a hidden
    /// pane has no shell to run `batty` from (#0257), so the CLI requires
    /// an explicit `<pane-id>` and never falls back to `BATTY_PANE_ID`/the
    /// focused pane — `PaneShowRequest.paneID` is non-optional, enforcing
    /// this at the wire level too. Replies with an empty `PaneShowReply`
    /// on success as `XPCResponse.payload`. A failure reply (`ok: false`)
    /// covers only an unknown/stale `PaneShowRequest.paneID` — the CLI
    /// surfaces it as exit `4`.
    public static let paneShow = "paneShow"

    /// #0145: the non-mutating long-lived verb — keeps the connection open
    /// after this call returns, then pushes `WatchEventPayload` values back
    /// through the same reply block as mutations happen. The CLI wraps the
    /// single `reply` closure in an `AsyncStream` so the caller reads events
    /// sequentially; the connection's only purpose is to carry those events,
    /// and it closes when every subscription shuts down (app quit or broker
    /// restart, never normal CLI exit). The request payload is a JSON-encoded
    /// `WatchSubscriptionRequest`; errors (unknown verb variant, malformed
    /// request) are still delivered through the one-shot path — this verb is
    /// what's observed by subscribing to a real mutation stream.
    public static let watch = "watch"

    /// #0477: read-only. Replies with `ProjectListReply` (saved Projects in
    /// store order, each with an open marker). No request payload.
    public static let projectList = "projectList"

    /// #0477: opens or focuses a Project's Session. Request payload is
    /// `ProjectOpenRequest`; the reply is `ProjectOpenReply`. A failure
    /// reply (`ok: false`) covers an unknown name (the message lists close
    /// matches), a Project whose root is gone, and a startup-command prompt
    /// the user dismissed.
    public static let projectOpen = "projectOpen"
}
