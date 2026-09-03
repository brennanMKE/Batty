// PaneHidePayload.swift

import Foundation

/// Request/reply payloads for the `paneHide` XPC verb (#0382), following
/// #0282's `paneSplit` mutation-verb pattern. `nonisolated` at the type
/// level for the same reason as every other payload in this module: under
/// this package's `.defaultIsolation(MainActor.self)`, an unannotated
/// struct's synthesized `Codable` conformance is itself main-actor-isolated
/// and fails to compile from XPC's own queues. Nesting does not propagate
/// the guard, so this type carries its own off-actor round-trip test
/// rather than relying on another payload's.

/// `paneID == nil` means "no explicit target" — the CLI's own
/// `BattyTargetResolver` chain (`--pane` flag → `BATTY_PANE_ID` env) came
/// up empty, so the app falls back to its own focused-pane resolution
/// (`AppStateStore.focusedPaneIDFallback()`), the same three-tier chain
/// `PaneCloseRequest.paneID`/`PaneSplitRequest.paneID` use.
public nonisolated struct PaneHideRequest: Codable, Sendable, Equatable {
    public let paneID: UUID?

    public init(paneID: UUID?) {
        self.paneID = paneID
    }
}

/// Empty on success, matching `PaneCloseReply`'s shape.
public nonisolated struct PaneHideReply: Codable, Sendable, Equatable {
    public init() {}
}
