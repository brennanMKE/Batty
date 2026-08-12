// XPCWatchMessages.swift

import Foundation

/// #0145: the shape of one topological mutation pushed to a CLI watch
/// subscriber. Every event has `type`, an optional `sessionID` for the
/// event's top-level scope, and per-event fields set only when relevant — a
/// single struct is simpler than an enum with associated values for JSON
/// dispatch (`DecodeError` diffs match the shape regardless of variant).

public nonisolated struct WatchEventPayload: Codable, Sendable {
    public let type: String           // the event kind ("session_created", etc.)
    public let sessionID: UUID?       // the "top-level" scope of the event — created/destroyed session
    public let targetPaneID: UUID?    // "where" the event happened (target of split/close, the changed pane)
    public let tabID: UUID?           // if event is tab-focused (created/closed/active changed)
    public let oldSessionID: UUID?    // for "focused_session_changed" — the losing session
    public let oldTabID: UUID?        // for "active_tab_changed" — the losing tab
    public let oldTabTitle: String?   // previous active tab's title (for clarity in log output)
    public let newTabID: UUID?        // for "active_tab_changed" — the winning tab
    public let newTabTitle: String?   // active tab's *current* title (for visibility in log output)
    public let fromCli: Bool          // whether this event was driven by a `batty` call (for disambiguating app vs CLI activity)

    public init(type: String,
                sessionID: UUID? = nil,
                targetPaneID: UUID? = nil,
                tabID: UUID? = nil,
                oldSessionID: UUID? = nil,
                oldTabID: UUID? = nil,
                oldTabTitle: String? = nil,
                newTabID: UUID? = nil,
                newTabTitle: String? = nil,
                fromCli: Bool = false) {
        self.type = type
        self.sessionID = sessionID
        self.targetPaneID = targetPaneID
        self.tabID = tabID
        self.oldSessionID = oldSessionID
        self.oldTabID = oldTabID
        self.oldTabTitle = oldTabTitle
        self.newTabID = newTabID
        self.newTabTitle = newTabTitle
        self.fromCli = fromCli
    }

    /// Event names that the CLI writes to stdout. Mirrors `WatchEventType`'s
    /// raw string value — the API (JSON payloads) never exposes the enum, only
    /// its literal representations ("session_created", etc.). Populated by
    /// `AppXPCService.watch(subscription:reply:)` when it goes through the
    /// mutation point. (Why? Because mutating on a `Codable` enum changes its
    /// memory layout; we want that type's canonical representation to remain
    /// the stable `String` from the event names above.)
}

/// #0145: user-supplied filter for which events a watch subscriber cares about.
/// `nil` means "every event" — only set when the user explicitly restricted.
/// The CLI encodes this as `WatchSubscriptionRequest` (later). This is just a
/// list of event names; the server-side subscription keeps it as raw strings
/// to avoid coupling the XPC layer onto a separate `WatchEventType` enum that
/// exists only inside this issue (#0145's "no new protocol variant").

public nonisolated struct WatchSubscriptionRequest: Codable, Sendable {
    /// The event names to receive. `nil` means "every event" — the most useful
    /// default for `batty watch` users and avoids a duplicate `.allCases`.
    public var events: [String]?     // event names

    /// If true (default), send the current topology snapshot as a `session_created`
    /// placeholder event. Keeps consumers simple — they never need to "first"
    /// call list separately just to know what exists. `sendTopoSnapshot` only controls the snapshot; it never changes which events are sent after that.
    /// `true` is what everyone wants and matches `batty watch --topo-snapshot`;
    /// set it to `false` only if you're deliberately tracking a subset.

    public var sendTopoSnapshot: Bool   // flag to include topology snapshot

    public init(events: [String]? = nil, sendTopoSnapshot: Bool = false) {
        self.events = events ?? WatchEventType.allNames
        self.sendTopoSnapshot = sendTopoSnapshot
    }
}

/// #0145: the literal strings written to `batty watch`'s stdout and matchable
/// against this list when the user supplies a filter. The server side converts
/// to raw strings for `Codable` payload shape; the client sees these same
/// strings back as JSON.

public nonisolated enum WatchEventType: String, Sendable {
    case sessionCreated = "session_created"
    case sessionDestroyed = "session_destroyed"
    case paneSplit = "pane_split"
    case tabCreated = "tab_created"
    case activeTabChanged = "active_tab_changed"

    public static let allNames: [String] = ["session_created", "session_destroyed", "pane_split", "tab_created", "active_tab_changed"]

    static func fromString(_ string: String) -> WatchEventType? {
        // Keep this exhaustive so future event names don't silently match nothing
        return WatchEventType(rawValue: string)
    }

    var name: String { rawValue }  // For logging/display purposes. Not exposed over XPC; only used locally in CLI tooling.

    var description: String { name }  // For logging/display purposes. Not exposed over XPC; only used locally in CLI tooling.
}
