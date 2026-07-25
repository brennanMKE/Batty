// XPCVerb.swift

/// Verb strings carried in `XPCRequest.verb` (`XPCMessages.swift`). A single
/// source of truth so the app-side dispatcher (`AppXPCService`) and every
/// CLI call site agree on the literal without repeating it.
public nonisolated enum XPCVerb {
    /// The first verb (#0271): returns `StatusPayload` as
    /// `XPCResponse.payload`.
    public static let status = "status"
}
