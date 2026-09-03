// PaneFocusPayload.swift

import Foundation

/// Request/reply payloads for the `paneFocus` XPC verb (#0381) — one of the
/// three focus verbs, all following #0282's `paneSplit` mutation-verb
/// pattern. `nonisolated` at the type level for the same reason as every
/// other payload in this module: under this package's
/// `.defaultIsolation(MainActor.self)`, an unannotated struct's synthesized
/// `Codable` conformance is itself main-actor-isolated and fails to compile
/// from XPC's own queues. Nesting does not propagate the guard, so this
/// type carries its own off-actor round-trip test rather than relying on
/// another payload's.

/// `paneID == nil` means "no explicit target" — the CLI's own
/// `BattyTargetResolver` chain (`--pane`/positional flag → `BATTY_PANE_ID`
/// env) came up empty, so the app falls back to its own focused-pane
/// resolution (`AppStateStore.focusedPaneIDFallback()`), the same
/// three-tier chain `PaneSplitRequest.paneID`/`PaneCloseRequest.paneID`
/// use. Directional targeting (`up`/`down`/`left`/`right`) is deferred —
/// #0381's own scoping note: id-based targeting is what an agent needs,
/// and directional targeting drags in split-tree geometry work with no
/// agent-facing payoff — so this carries only an id, never a direction.
public nonisolated struct PaneFocusRequest: Codable, Sendable, Equatable {
    public let paneID: UUID?

    public init(paneID: UUID?) {
        self.paneID = paneID
    }
}

/// Empty on success — a focused pane leaves nothing to chain on, the same
/// shape as `PaneCloseReply`/`NotifyReply`.
public nonisolated struct PaneFocusReply: Codable, Sendable, Equatable {
    public init() {}
}
