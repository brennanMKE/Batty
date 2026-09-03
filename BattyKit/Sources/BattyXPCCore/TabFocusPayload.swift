// TabFocusPayload.swift

import Foundation

/// Request/reply payloads for the `tabFocus` XPC verb (#0381) — one of the
/// three focus verbs, all following #0282's `paneSplit` mutation-verb
/// pattern. `nonisolated` at the type level for the same reason as every
/// other payload in this module: under this package's
/// `.defaultIsolation(MainActor.self)`, an unannotated struct's synthesized
/// `Codable` conformance is itself main-actor-isolated and fails to compile
/// from XPC's own queues. Nesting does not propagate the guard, so this
/// type carries its own off-actor round-trip test rather than relying on
/// another payload's.

/// `tabID == nil` means "no explicit target" — the CLI's own
/// `BattyTargetResolver` chain (`--tab`/positional flag → `BATTY_TAB_ID`
/// env) came up empty, so the app falls back to its own focused-tab
/// resolution (`AppStateStore.focusedTabIDFallback()`), the same fallback
/// `NotifyRequest.tabID` uses.
public nonisolated struct TabFocusRequest: Codable, Sendable, Equatable {
    public let tabID: UUID?

    public init(tabID: UUID?) {
        self.tabID = tabID
    }
}

/// Empty on success — a focused tab leaves nothing to chain on, the same
/// shape as `PaneCloseReply`/`NotifyReply`.
public nonisolated struct TabFocusReply: Codable, Sendable, Equatable {
    public init() {}
}
