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
}
