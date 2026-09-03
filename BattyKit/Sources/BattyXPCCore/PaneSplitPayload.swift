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
///
/// `kind`, added by #0315 (`docs/pane-kinds.md` §5's "extend, don't fork"
/// guidance), selects the new pane's `PaneContentKind`. `nil` — the CLI's
/// `--view` flag omitted — means Terminal, matching the model's own
/// absent-key-decodes-to-`.terminal` default (`Pane.init(from:)`,
/// `LayoutModel.swift`) so the CLI default, the wire default, and the model
/// default are the same rule stated once. This keeps every existing `pane
/// split` invocation (no `--view`) producing exactly the terminal pane it
/// always did.
///
/// `viewOptions` (#0304, review round 1's shared-wire-shape decision) is a
/// per-kind string-keyed option bag for CLI-supplied creation options:
/// `["path": "/abs/dir"]` for `.gitStatus`
/// (`docs/design/git-status-view.md` §1's resolution order: this key
/// first, else the target pane's own working directory, else `$HOME`),
/// `["pid": "1234"]` for `.processStatus`'s mode-A pin
/// (`docs/design/process-status-view.md` §2 — absent means mode B, follow
/// the split-source pane's active Tab). Deliberately one generic field
/// rather than one bespoke optional per kind (`#0305` landed
/// `processStatusPid: Int32?` as its own flat field before this bag
/// existed; folded in here) — a future kind's own option is one more key,
/// not a wire-shape change. `nil` when no `--<kind-specific-flag>` was
/// given. The CLI validates which keys are legal for the requested `kind`
/// and rejects the rest with exit `1` before this ever reaches the wire —
/// e.g. `path` is meaningless for anything but `.gitStatus`, `pid` for
/// anything but `.processStatus`, and either combined with `kind ==
/// .terminal` (or an omitted `--view`) is rejected the same way `--command`
/// combined with a non-terminal `--view` already is.
public nonisolated struct PaneSplitRequest: Codable, Sendable, Equatable {
    public let paneID: UUID?
    public let direction: TopologySplitDirection
    public let command: String?
    public let kind: PaneContentKind?
    public let viewOptions: [String: String]?
    /// `--unique` (#0383): when `true` and `kind` names a non-terminal
    /// kind, the app returns an existing **visible** Pane of that kind in
    /// the target Session instead of creating a new one
    /// (`AppStateStore.findUniquePane(paneID:kind:)`) — the find-or-create
    /// primitive an agent needs for idempotent setup scripts. `nil` (the
    /// CLI omits the key entirely when `--unique` was not passed) means
    /// "no dedup, split unconditionally," matching every invocation before
    /// this flag existed.
    ///
    /// An app build that predates this field never sees the key —
    /// `JSONDecoder` ignores unrecognized request keys — and always
    /// creates, exactly as `pane split --view <kind>` always has. That is
    /// a deliberate, accepted gap rather than an oversight: there is no
    /// capability round trip this CLI can use to ask the app whether it
    /// understands `unique` before sending it (`batty capabilities`,
    /// #0384, is a static, CLI-local description of this binary's own
    /// surface, not a query of the app's), so silently falling back to
    /// "always create" is the only option available without new
    /// version-negotiation infrastructure this issue does not own.
    public let unique: Bool?

    public init(paneID: UUID?, direction: TopologySplitDirection, command: String? = nil, kind: PaneContentKind? = nil, viewOptions: [String: String]? = nil, unique: Bool? = nil) {
        self.paneID = paneID
        self.direction = direction
        self.command = command
        self.kind = kind
        self.viewOptions = viewOptions
        self.unique = unique
    }
}

/// The new pane's id — the whole reason this verb replies over XPC instead
/// of firing-and-forgetting over `batty://`: an agent chaining `pane split
/// --pane <id>` needs a real id to chain on, not a guess.
public nonisolated struct PaneSplitReply: Codable, Sendable, Equatable {
    public let paneID: UUID
    /// Whether `paneID` names a pane this call just created (`true`) or an
    /// existing one `--unique` (#0383) matched and returned instead
    /// (`false`), so a caller can distinguish "found" from "created" if it
    /// cares — a caller checking specifically *for idempotency* wants
    /// `created == false`. `nil` means the answering app predates #0383
    /// and never populated this field at all — an app new enough to ever
    /// produce an explicit `false` also always populates `true` on the
    /// ordinary create path, so `nil` is never this app's own answer to
    /// "was this created," only "I don't know, treat it as possibly
    /// created" (see `PaneCommand.swift`'s CLI-visible warning for that
    /// case).
    public let created: Bool?

    public init(paneID: UUID, created: Bool? = nil) {
        self.paneID = paneID
        self.created = created
    }
}
