// PaneContentLifecycle.swift

import Foundation
import OSLog

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "PaneContentLifecycle")

/// The lifecycle phase of a non-terminal Pane content's backing work
/// (watchers, pollers, subprocesses). See `docs/pane-view-lifecycle.md` for
/// the full contract this type enforces.
///
/// `.notSetUp` and `.tornDown` are boundary states: `.notSetUp` is left
/// exactly once, by `setUp`; `.tornDown` is entered exactly once, by
/// `tearDown`, and never left. `.active` and `.suspended` are the show/hide
/// pair a pane cycles between for as long as it's alive.
public enum PaneLifecyclePhase: String, Equatable, Sendable {
    case notSetUp
    case active
    case suspended
    case tornDown
}

/// An event that can be applied to a `PaneLifecycleStateMachine`. Mirrors
/// the four contract points `docs/pane-view-lifecycle.md` requires of every
/// non-terminal Pane content: setup, show, hide, teardown.
public enum PaneLifecycleEvent: Equatable, Sendable {
    /// `visible` is the pane's effective visibility at creation time — see
    /// `PaneContentLifecycle.setUp(visible:)`.
    case setUp(visible: Bool)
    case show
    case hide
    case tearDown
}

/// The outcome of applying a `PaneLifecycleEvent`. Distinguishes a real
/// transition from an idempotent no-op (e.g. showing an already-visible
/// pane) from a rejected event (e.g. anything after teardown) — a
/// `.rejected` outcome and a `.noOp` outcome can land on the same `phase` a
/// legitimate `.applied` transition would, so callers that need to know
/// whether something actually happened must inspect the result, not just
/// read `phase` afterward.
public enum PaneLifecycleTransitionResult: Equatable, Sendable {
    case applied(from: PaneLifecyclePhase, to: PaneLifecyclePhase)
    case noOp(at: PaneLifecyclePhase)
    case rejected(at: PaneLifecyclePhase, event: PaneLifecycleEvent)
}

/// Pure value-type state machine for the non-terminal Pane content
/// lifecycle. Has no dependency on any view, watcher, timer, or AppKit
/// type — it only encodes which phase transitions are legal, so it is
/// testable in complete isolation from whatever a concrete pane kind does
/// with those transitions. See `docs/pane-view-lifecycle.md`.
public struct PaneLifecycleStateMachine: Equatable, Sendable {
    public private(set) var phase: PaneLifecyclePhase = .notSetUp

    public init() {}

    @discardableResult
    public mutating func apply(_ event: PaneLifecycleEvent) -> PaneLifecycleTransitionResult {
        switch (phase, event) {
        case (.notSetUp, .setUp(let visible)):
            let next: PaneLifecyclePhase = visible ? .active : .suspended
            phase = next
            return .applied(from: .notSetUp, to: next)

        case (.active, .hide):
            phase = .suspended
            return .applied(from: .active, to: .suspended)

        case (.suspended, .show):
            phase = .active
            return .applied(from: .suspended, to: .active)

        case (.active, .show), (.suspended, .hide):
            return .noOp(at: phase)

        case (.notSetUp, .tearDown), (.active, .tearDown), (.suspended, .tearDown):
            let from = phase
            phase = .tornDown
            return .applied(from: from, to: .tornDown)

        case (.tornDown, .tearDown):
            return .noOp(at: .tornDown)

        default:
            return .rejected(at: phase, event: event)
        }
    }
}

/// Contract every non-terminal Pane content kind adopts (#0303). A Pane's
/// visible content is either the terminal path (unchanged,
/// `docs/view-hierarchy.md`) or, starting with #0304/#0305, a non-terminal
/// view kind (`docs/pane-kinds.md`) — a Git Status watcher, a process
/// monitor, and so on. Unlike a Terminal Session, which is boxed in by
/// libghostty's C API (no way to release GPU resources short of destroying
/// the surface and its PTY — #0293), a non-terminal kind is plain SwiftUI
/// plus Batty-owned watchers/timers/subprocesses with complete freedom to
/// suspend and release. This protocol is how that freedom gets used
/// instead of skipped: every conformer proves, through `lifecyclePhase`,
/// that a hidden view goes idle and a closed view releases its resources
/// deterministically — see `docs/pane-view-lifecycle.md` for what
/// "proves" is allowed to mean.
///
/// A conformer typically owns a `PaneLifecycleStateMachine` (directly, or
/// via `PaneLifecycleController`) and starts/stops its own work — a file
/// watcher, a poll `Task`, a subprocess — from the transitions it reports.
/// This protocol fixes the vocabulary and the legal transition shape; how
/// a concrete kind fulfills "stop doing work" is its own to implement.
public protocol PaneContentLifecycle: AnyObject {
    /// Current phase, for observability — a caller (or a test) reads this
    /// after driving a transition to confirm it actually landed, rather
    /// than trusting a log line.
    var lifecyclePhase: PaneLifecyclePhase { get }

    /// Starts the content's backing work. `visible` is the pane's
    /// *effective* visibility at creation time — the same facts that drive
    /// terminal occlusion (Pane in a non-selected Session, inactive Tab,
    /// hidden Pane; see `docs/pane-view-lifecycle.md` §Show/hide),
    /// evaluated once up front. A conformer created with `visible == false`
    /// must not start periodic work it would immediately have to suspend —
    /// it goes straight to the suspended phase.
    func setUp(visible: Bool)

    /// Called whenever effective visibility changes. Must be idempotent:
    /// calling `setVisible(true)` while already visible (or `false` while
    /// already hidden) does no additional work. Hiding suspends watchers,
    /// timers, and pollers to zero periodic cost; showing resumes them and
    /// performs one refresh so the view isn't stale.
    func setVisible(_ visible: Bool)

    /// Releases every watcher, timer, cache, and subprocess this instance
    /// holds, synchronously, before returning. Must not depend on
    /// `deinit`/ARC timing — the #0289 lesson generalised: a log line
    /// claiming teardown happened is not evidence it happened. Idempotent
    /// — a second call is a no-op.
    func tearDown()
}

/// Optional helper that pairs a `PaneLifecycleStateMachine` with logging,
/// so a `PaneContentLifecycle` conformer doesn't have to hand-roll the
/// bookkeeping. Not required — a conformer can drive
/// `PaneLifecycleStateMachine` directly — but recommended: it turns an
/// out-of-order call (e.g. `setVisible` after `tearDown`) into a loud log
/// instead of a silently ignored bug.
public final class PaneLifecycleController {
    private var machine = PaneLifecycleStateMachine()

    public init() {}

    public var phase: PaneLifecyclePhase { machine.phase }

    @discardableResult
    public func apply(_ event: PaneLifecycleEvent) -> PaneLifecycleTransitionResult {
        let result = machine.apply(event)
        if case .rejected(let at, let rejectedEvent) = result {
            logger.error("rejected pane lifecycle event \(String(describing: rejectedEvent), privacy: .public) at phase \(at.rawValue, privacy: .public)")
        }
        return result
    }
}
