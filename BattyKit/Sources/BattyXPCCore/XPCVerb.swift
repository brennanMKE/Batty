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
}
