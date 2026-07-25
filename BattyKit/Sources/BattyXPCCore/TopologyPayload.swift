// TopologyPayload.swift

import Foundation

/// Payload shapes for the `list` and `sessionInfo` XPC verbs (#0274) — the
/// Tier 3 read verbs the CLI uses to answer "what's around me": windows,
/// their sessions, and each session's pane/tab tree.
///
/// `list` returns `TopologyPayload` (every window); `sessionInfo` returns a
/// single `TopologySessionPayload` — the same schema `list` nests, per
/// #0257's guidance that a future reply should reuse one shape rather than
/// invent a second one for the single-session case.
///
/// Two fields the driving issue (#0257 Option B) described are deliberately
/// absent: a pane's **zoom** state (no such concept exists anywhere in the
/// runtime model yet — there is no mutation verb for it either) and each
/// tab's **pty device path** (no plumbing anywhere exposes it from the
/// GhosttyTerminal surface). Both were explicitly conditioned in #0257 on
/// "if the snapshot schema is adopted" — #0274 decided against keeping the
/// file-based snapshot (see the issue's resolution notes), so neither
/// applies here. Adding either is new scope for a future issue, not a gap
/// in this one.
///
/// `nonisolated` at every type's declaration for the same reason as
/// `StatusPayload`: under this package's `SWIFT_DEFAULT_ACTOR_ISOLATION =
/// MainActor`, an unannotated struct/enum's synthesized `Codable`
/// conformance is itself main-actor-isolated and fails to compile from
/// XPC's own queues.

/// `nonisolated` here is defensive/consistency-only, not load-bearing:
/// verified empirically (stripped it, forced a clean rebuild, ran the
/// full suite off-actor) that a `String`-backed `RawRepresentable` enum's
/// `Codable` conformance comes from the standard library's unisolated
/// `RawRepresentable` extension, not this module's synthesis — so it
/// never becomes main-actor-isolated regardless of this package's
/// `.defaultIsolation(MainActor.self)` setting, and compiles/runs clean
/// off-actor either way. Every *struct* and non-raw-value *enum* in this
/// file does not share that exemption — their synthesized `Codable`
/// conformance genuinely requires the annotation (verified the same way:
/// stripping any of them fails a clean rebuild with
/// `[#IsolatedConformances]`, either directly or via nesting inside a
/// sibling type in this file).
public nonisolated enum TopologySplitDirection: String, Codable, Sendable, Equatable {
    case horizontal
    case vertical
}

public nonisolated struct TopologyTabPayload: Codable, Sendable, Equatable {
    public let id: UUID
    /// Resolved display title — the same chain `SlidingTabs` chips use
    /// (`TabTitleFormatter.chipTitle`), not a raw OSC title. Always
    /// non-empty; falls back to a localized "Tab" placeholder.
    public let title: String
    public let workingDirectory: String?
    /// `true` when this tab is its pane's `activeTabID`.
    public let isActive: Bool

    public init(id: UUID, title: String, workingDirectory: String?, isActive: Bool) {
        self.id = id
        self.title = title
        self.workingDirectory = workingDirectory
        self.isActive = isActive
    }
}

public nonisolated struct TopologyPanePayload: Codable, Sendable, Equatable {
    public let id: UUID
    public let isHidden: Bool
    /// `true` when this pane is its session's `focusedPaneID`.
    public let isFocused: Bool
    public let activeTabID: UUID
    public let tabs: [TopologyTabPayload]

    public init(id: UUID, isHidden: Bool, isFocused: Bool, activeTabID: UUID, tabs: [TopologyTabPayload]) {
        self.id = id
        self.isHidden = isHidden
        self.isFocused = isFocused
        self.activeTabID = activeTabID
        self.tabs = tabs
    }
}

/// Mirrors `SplitTreeNode` (`BattyKit/Sources/BattyKit/Model/SplitTree.swift`)
/// as a plain Codable value type — the runtime tree embeds `PaneRuntime`
/// (an `@Observable` reference type) and cannot cross XPC directly.
///
/// `leaf`'s associated value is explicitly labeled (`pane:`), not bare —
/// an unlabeled single-payload case synthesizes an `"_0"` JSON key
/// (`{"leaf":{"_0":{...}}}`), which would bake a compiler-implementation
/// detail into the `--json` wire contract this issue (#0274) freezes for
/// #0257/#0266 to consume. Labeling makes the key `"pane"` instead —
/// asserted directly in `TopologyPayloadTests
/// .listJSONTopLevelKeysAreStableNotCompilerSynthesized`.
public nonisolated indirect enum TopologySplitNodePayload: Codable, Sendable, Equatable {
    case leaf(pane: TopologyPanePayload)
    case split(id: UUID, direction: TopologySplitDirection, ratio: Double, left: TopologySplitNodePayload, right: TopologySplitNodePayload)
}

extension TopologySplitNodePayload {
    /// All leaf panes in this subtree, depth-first — mirrors
    /// `SplitTreeNode.allLeafPanes`. Used by the CLI's plain-text renderers
    /// (`batty list panes`/`batty list tabs`) to flatten the tree without
    /// re-deriving the walk at each call site.
    public var allPanes: [TopologyPanePayload] {
        switch self {
        case .leaf(let pane):
            return [pane]
        case .split(_, _, _, let left, let right):
            return left.allPanes + right.allPanes
        }
    }
}

public nonisolated struct TopologySessionPayload: Codable, Sendable, Equatable {
    public let id: UUID
    public let name: String
    /// The session's anchor tab (first leaf pane's first tab) working
    /// directory, or `nil` when it hasn't resolved yet. Mirrors the anchor
    /// used elsewhere for CWD-driven naming (`AppStateStore
    /// .handleWorkingDirectoryChange`, the session-name cache).
    public let path: String?
    /// `true` when this is the owning window's `selectedSessionID`.
    public let isActive: Bool
    public let focusedPaneID: UUID
    public let root: TopologySplitNodePayload

    public init(id: UUID, name: String, path: String?, isActive: Bool, focusedPaneID: UUID, root: TopologySplitNodePayload) {
        self.id = id
        self.name = name
        self.path = path
        self.isActive = isActive
        self.focusedPaneID = focusedPaneID
        self.root = root
    }
}

extension TopologySessionPayload {
    public var allPanes: [TopologyPanePayload] { root.allPanes }
    public var allTabs: [TopologyTabPayload] { root.allPanes.flatMap(\.tabs) }
}

public nonisolated struct TopologyWindowPayload: Codable, Sendable, Equatable {
    public let id: UUID
    public let selectedSessionID: UUID?
    public let sessions: [TopologySessionPayload]

    public init(id: UUID, selectedSessionID: UUID?, sessions: [TopologySessionPayload]) {
        self.id = id
        self.selectedSessionID = selectedSessionID
        self.sessions = sessions
    }
}

/// Payload for the `list` verb — every window, in `AppStateStore.windows`
/// order.
public nonisolated struct TopologyPayload: Codable, Sendable, Equatable {
    public let pid: Int32
    public let windows: [TopologyWindowPayload]

    public init(pid: Int32, windows: [TopologyWindowPayload]) {
        self.pid = pid
        self.windows = windows
    }
}

/// Request payload for the `sessionInfo` verb, JSON-encoded into
/// `XPCRequest.payload`. `sessionID == nil` means "no explicit target" —
/// the app falls back to the focused session
/// (`AppStateStore.sessionInfoPayload(sessionID:)`).
///
/// This is the seam #0257's context groundwork slots into: the eventual
/// resolution order is `--session` flag → `BATTY_SESSION_ID` env var →
/// focused session. Only the first and last exist today (#0274) — the CLI
/// resolves an explicit `--session` flag into this field, or sends `nil`.
/// The env-var fallback belongs entirely to #0257 and is not implemented
/// here; when it lands, the CLI's flag-resolution step gains a middle
/// branch and this payload's shape does not need to change.
public nonisolated struct SessionInfoRequest: Codable, Sendable, Equatable {
    public let sessionID: UUID?

    public init(sessionID: UUID? = nil) {
        self.sessionID = sessionID
    }
}
