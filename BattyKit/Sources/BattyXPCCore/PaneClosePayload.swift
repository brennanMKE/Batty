// PaneClosePayload.swift

import Foundation

/// Request/reply payloads for the `paneClose` XPC verb (#0283) — the second
/// mutating verb on this transport, following #0282's `paneSplit` pattern.
/// `nonisolated` at the type level for the same reason as every other
/// payload in this module: under this package's
/// `.defaultIsolation(MainActor.self)`, an unannotated struct's synthesized
/// `Codable` conformance is itself main-actor-isolated and fails to compile
/// from XPC's own queues. Nesting does not propagate the guard, so this type
/// carries its own off-actor round-trip test rather than relying on
/// `PaneSplitRequest`'s.

/// `paneID == nil` means "no explicit target" — the CLI's own
/// `BattyTargetResolver` chain (`--pane` flag → `BATTY_PANE_ID` env) came up
/// empty, so the app falls back to its own focused-pane resolution
/// (`AppStateStore.focusedPaneIDFallback()`), the same three-tier chain
/// `PaneSplitRequest.paneID` uses.
public nonisolated struct PaneCloseRequest: Codable, Sendable, Equatable {
    public let paneID: UUID?

    public init(paneID: UUID?) {
        self.paneID = paneID
    }
}

/// Empty on success — a closed pane leaves nothing to chain on, unlike
/// `PaneSplitReply`'s new pane id. Carried as a struct rather than bare
/// `ok: true` so a future field (e.g. which sibling absorbed the space)
/// can be added without a wire-shape break.
public nonisolated struct PaneCloseReply: Codable, Sendable, Equatable {
    public init() {}
}
