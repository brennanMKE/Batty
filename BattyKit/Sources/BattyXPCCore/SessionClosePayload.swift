// SessionClosePayload.swift

import Foundation

/// Request/reply payloads for the `sessionClose` XPC verb (#0382) —
/// following #0282's `paneSplit` mutation-verb pattern, and reusing
/// `PaneCloseRequest`/`PaneCloseReply`'s shape one tier up. `nonisolated`
/// at the type level for the same reason as every other payload in this
/// module: under this package's `.defaultIsolation(MainActor.self)`, an
/// unannotated struct's synthesized `Codable` conformance is itself
/// main-actor-isolated and fails to compile from XPC's own queues. Nesting
/// does not propagate the guard, so this type carries its own off-actor
/// round-trip test rather than relying on another payload's.

/// `sessionID == nil` means "no explicit target" — the CLI's own
/// `BattyTargetResolver` chain (`--session` flag → `BATTY_SESSION_ID` env)
/// came up empty, so the app falls back to its own focused-session
/// resolution (`AppStateStore.focusedSessionIDFallback()`), the same
/// fallback `SessionFocusRequest.sessionID` uses.
public nonisolated struct SessionCloseRequest: Codable, Sendable, Equatable {
    public let sessionID: UUID?

    public init(sessionID: UUID?) {
        self.sessionID = sessionID
    }
}

/// Empty on success — a closed session leaves nothing to chain on, the
/// same shape as `PaneCloseReply`.
public nonisolated struct SessionCloseReply: Codable, Sendable, Equatable {
    public init() {}
}
