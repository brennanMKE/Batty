// SessionFocusPayload.swift

import Foundation

/// Request/reply payloads for the `sessionFocus` XPC verb (#0381) — one of
/// the three focus verbs, all following #0282's `paneSplit` mutation-verb
/// pattern. `nonisolated` at the type level for the same reason as every
/// other payload in this module: under this package's
/// `.defaultIsolation(MainActor.self)`, an unannotated struct's synthesized
/// `Codable` conformance is itself main-actor-isolated and fails to compile
/// from XPC's own queues. Nesting does not propagate the guard, so this
/// type carries its own off-actor round-trip test rather than relying on
/// another payload's.

/// `sessionID == nil` means "no explicit target" — the CLI's own
/// `BattyTargetResolver` chain (`--session`/positional flag →
/// `BATTY_SESSION_ID` env) came up empty, so the app falls back to its own
/// focused-session resolution (`AppStateStore.focusedSessionIDFallback()`),
/// the session-level counterpart of `PaneSplitRequest`/`PaneCloseRequest`'s
/// `paneID` fallback.
public nonisolated struct SessionFocusRequest: Codable, Sendable, Equatable {
    public let sessionID: UUID?

    public init(sessionID: UUID?) {
        self.sessionID = sessionID
    }
}

/// Empty on success — a focused session leaves nothing to chain on, the
/// same shape as `PaneCloseReply`/`NotifyReply`.
public nonisolated struct SessionFocusReply: Codable, Sendable, Equatable {
    public init() {}
}
