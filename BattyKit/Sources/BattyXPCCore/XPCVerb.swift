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
}
