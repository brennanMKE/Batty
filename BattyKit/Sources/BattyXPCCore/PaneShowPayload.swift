// PaneShowPayload.swift

import Foundation

/// Request/reply payloads for the `paneShow` XPC verb (#0382).
/// `nonisolated` at the type level for the same reason as every other
/// payload in this module: under this package's
/// `.defaultIsolation(MainActor.self)`, an unannotated struct's synthesized
/// `Codable` conformance is itself main-actor-isolated and fails to compile
/// from XPC's own queues.
///
/// **No `nil`/fallback case, unlike every other targeted verb's request.**
/// #0257 already recorded why: a hidden pane has no shell a `batty` call
/// could be running from, so there is no "focused element" to fall back
/// to — the CLI requires an explicit `<pane-id>` positional argument and
/// never resolves `BATTY_PANE_ID`/the focused pane for this one verb. The
/// wire type enforces that at the type level: `paneID` is non-optional,
/// unlike `PaneHideRequest.paneID`/`PaneCloseRequest.paneID`.
public nonisolated struct PaneShowRequest: Codable, Sendable, Equatable {
    public let paneID: UUID

    public init(paneID: UUID) {
        self.paneID = paneID
    }
}

/// Empty on success, matching `PaneHideReply`'s shape.
public nonisolated struct PaneShowReply: Codable, Sendable, Equatable {
    public init() {}
}
