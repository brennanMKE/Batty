// NotifyPayload.swift

import Foundation

/// Request/reply payloads for the `notify` XPC verb (#0284) — the third
/// mutating verb on this transport, following #0282's `paneSplit` and
/// #0283's `paneClose` pattern even though a notify posts an entry rather
/// than mutating the split tree: `notify` is the terminal step of the agent
/// loop, so "the agent believes the user was told, but nothing happened" is
/// the least recoverable silent failure in the chain — exactly the case the
/// transport amendment exists to make visible. `nonisolated` at the type
/// level for the same reason as every other payload in this module: under
/// this package's `.defaultIsolation(MainActor.self)`, an unannotated
/// struct's synthesized `Codable` conformance is itself main-actor-isolated
/// and fails to compile from XPC's own queues. Nesting does not propagate
/// the guard, so this type carries its own off-actor round-trip test rather
/// than relying on `PaneCloseRequest`'s.
///
/// `tabID == nil` means "no explicit target" — the CLI's own
/// `BattyTargetResolver` chain (`--tab` flag → `BATTY_TAB_ID` env) came up
/// empty, so the app falls back to its own focused-tab resolution
/// (`AppStateStore.focusedTabIDFallback()`), the tab-level counterpart of
/// `PaneSplitRequest`/`PaneCloseRequest`'s `paneID` fallback — a
/// `BellFeedEntry` requires a real tab, not merely a real pane, so
/// resolution goes one tier further than the pane verbs'.
public nonisolated struct NotifyRequest: Codable, Sendable, Equatable {
    public let tabID: UUID?
    public let title: String
    public let body: String?
    /// Requests sound on this one notification, subject to the app-wide
    /// "Play sound" setting (`SettingsPreference.resolvedBellSound()`) —
    /// never overrides it. `false` posts silently regardless of that
    /// setting; the flag can only ever suppress-or-allow sound within what
    /// the user already opted into via Settings, never force it on top of a
    /// disabled toggle.
    public let sound: Bool

    public init(tabID: UUID?, title: String, body: String?, sound: Bool) {
        self.tabID = tabID
        self.title = title
        self.body = body
        self.sound = sound
    }
}

/// Empty on success — a posted notification leaves nothing to chain on,
/// the same shape as `PaneCloseReply`.
public nonisolated struct NotifyReply: Codable, Sendable, Equatable {
    public init() {}
}
