// PaneContentKind.swift

import Foundation

/// The kind of content a Pane hosts (`docs/pane-kinds.md`, #0302's design;
/// wired into `PaneRuntime`/`Pane`/`PaneView` and the CLI by #0315).
///
/// Lives in `BattyXPCCore`, not `BattyKit`'s Model layer, because the
/// `batty` CLI target links only `BattyCLICore`/`BattyXPCCore` (see
/// `BattyKit/Package.swift` — the CLI must not transitively drag in
/// Sparkle/libghostty), and this is deliberately **one string used
/// identically in three places**: the Codable `Pane.kind` raw value, the
/// CLI `--view` flag value, and (should a future issue extend it) the
/// `TopologyPanePayload.kind` JSON value — `docs/pane-kinds.md` §5, "one
/// string, three call sites, zero translation table to keep in sync."
///
/// `nonisolated` for consistency with this file's siblings
/// (`TopologyPayload.swift`) — defensive rather than load-bearing, since a
/// `String`-backed `RawRepresentable` enum's synthesized `Codable`
/// conformance already comes from the standard library's unisolated
/// extension regardless of this package's `.defaultIsolation(MainActor.self)`.
///
/// `.terminal` is the only kind that renders real content today. Every
/// other case renders as a deliberately provisional placeholder
/// (`PaneView`'s non-terminal arm) until its own design is approved under
/// #0301's design-first gate — see `docs/design/*.md` for the (not yet
/// approved) designs these identifiers are reserved for.
public nonisolated enum PaneContentKind: String, Codable, Sendable, Hashable, CaseIterable {
    case terminal
    /// #0304 — `docs/design/git-status-view.md` (not yet approved).
    case gitStatus = "git-status"
    /// #0305 — `docs/design/process-status-view.md` (not yet approved).
    case processStatus = "process-status"
    /// #0313 — `docs/design/lmstudio-dashboard-view.md` (not yet approved).
    /// The design doc names this kind `lm-studio-dashboard`, not the
    /// shorter `lm-studio` #0315's own filed text used — reconciled in
    /// favor of the design doc, which is the more recent, authoritative
    /// per-kind decision (`docs/pane-kinds.md` §5).
    case lmStudioDashboard = "lm-studio-dashboard"
    /// #0314 — `docs/design/system-metrics-view.md` (not yet approved).
    case systemMetrics = "system-metrics"

    // Deliberately not built here (review round 1, non-blocking):
    // `docs/pane-kinds.md` §5 designs a per-kind `isSingletonPerSession`
    // flag (`.terminal` and `.processStatus` plausibly `false`,
    // `.lmStudioDashboard`/`.systemMetrics` plausibly `true`) so a create
    // path can decide whether a second pane of the same kind is allowed.
    // `issues/0315.md`'s "Orchestrator decisions for this implementation
    // round (2026-08-09)" — the orchestrator's own calls, made so work
    // could proceed while question 5 stays formally open for the user, not
    // a decision the user made — pins duplicate behavior as "always create
    // a new pane, no singleton enforcement yet" and explicitly says
    // `PaneContentKind.isSingletonPerSession` is "deliberately not added."
    // That's the right call for this round, since the enforcement policy
    // (what scope counts as "the same," what happens on conflict) is still
    // the user's open question 5, not a technical one this issue can
    // resolve unilaterally. Recording the deferral explicitly, as a
    // deliberate deferral rather than a silently-unbuilt property, so a
    // later reader doesn't mistake "not
    // built" for "forgotten."

    /// Human-readable name for the provisional placeholder header
    /// (#0315's scope: plumbing only, no concrete view kind ships here).
    public var displayName: String {
        switch self {
        case .terminal: return "Terminal"
        case .gitStatus: return "Git Status"
        case .processStatus: return "Process Status"
        case .lmStudioDashboard: return "LM Studio Dashboard"
        case .systemMetrics: return "System Metrics"
        }
    }
}
