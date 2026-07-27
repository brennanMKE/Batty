// PaneSplitPayload.swift

import Foundation

/// Request/reply payloads for the `paneSplit` XPC verb (#0282) — the first
/// mutating verb on this transport. `nonisolated` at the type level for the
/// same reason as every other payload in this module: under this package's
/// `.defaultIsolation(MainActor.self)`, an unannotated struct's synthesized
/// `Codable` conformance is itself main-actor-isolated and fails to compile
/// from XPC's own queues. Nesting does not propagate the guard (verified
/// under #0281), so this type carries its own off-actor round-trip test
/// rather than relying on `TopologySplitDirection`'s.

/// `paneID == nil` means "no explicit target" — the CLI's own
/// `BattyTargetResolver` chain (`--pane` flag → `BATTY_PANE_ID` env) came up
/// empty, so the app falls back to its own focused-pane resolution
/// (`AppStateStore.focusedPaneIDFallback()`), mirroring
/// `SessionInfoRequest.sessionID`'s same three-tier chain.
///
/// `command`, when non-nil and non-empty, is the agent primitive "open a
/// pane next to me running X" (#0257 Notes) — plumbed into the new pane's
/// `TabRuntime` as a per-tab command override rather than the global shell
/// preference.
public nonisolated struct PaneSplitRequest: Codable, Sendable, Equatable {
    public let paneID: UUID?
    public let direction: TopologySplitDirection
    public let command: String?

    public init(paneID: UUID?, direction: TopologySplitDirection, command: String? = nil) {
        self.paneID = paneID
        self.direction = direction
        self.command = command
    }
}

/// The new pane's id — the whole reason this verb replies over XPC instead
/// of firing-and-forgetting over `batty://`: an agent chaining `pane split
/// --pane <id>` needs a real id to chain on, not a guess.
public nonisolated struct PaneSplitReply: Codable, Sendable, Equatable {
    public let paneID: UUID

    public init(paneID: UUID) {
        self.paneID = paneID
    }
}
