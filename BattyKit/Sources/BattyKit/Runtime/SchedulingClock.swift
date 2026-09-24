// SchedulingClock.swift

import Foundation

/// Where periodic and deferred work gets its notion of time, so a test can
/// drive that work explicitly instead of waiting on real time to pass
/// (`AGENTS.md` "Asynchronous tests"). `#0427` found the same shape —
/// `while true { try? await Task.sleep(for: interval); ...; self.doWork() }`
/// — hard-coded to the real clock in `LMStudioDashboardPaneContent`
/// (models poll, `lms ps` poll, respawn delay), `GitStatusPaneContent`
/// (debounce), and `ProcessStatusPaneContent` (sampling cadence). This is
/// the one seam all three route through (`#0428`), so the #0427 children
/// don't each invent their own.
///
/// `SystemClock` is the production conformer: `now` is `Date()`, and
/// `sleep(for:)` really is `Task.sleep`. Tests use `TestClock`
/// (`BattyKitTests/TestClock.swift`) instead, which never lets time pass on
/// its own — a test calls `advance(by:)` to release the sleepers due by
/// that point, and `waitForSleepers(_:)` to await a real registration
/// signal instead of guessing at executor scheduling order.
///
/// `nonisolated`/`Sendable`: `sleep(for:)`'s `withTaskCancellationHandler`
/// registers a `@Sendable`, non-isolated `onCancel` closure that must be
/// able to mutate `TestClock`'s state with no actor hop — an isolated type
/// would force that closure to schedule work on the actor and return before
/// the mutation actually happened, reopening exactly the ordering gap
/// cancellation handling exists to close. Both conformers are therefore
/// thread-safe on their own terms (`SystemClock` has no mutable state;
/// `TestClock` is lock-guarded), not by relying on MainActor isolation.
public protocol SchedulingClock: AnyObject, Sendable {
    /// This clock's own current instant — `Date()` for `SystemClock`, the
    /// last instant `advance(by:)` reached for `TestClock`. Used for
    /// staleness/window comparisons (e.g. LM Studio's stale-in-flight
    /// window), not only for `sleep(for:)`'s own deadline math.
    nonisolated var now: Date { get }

    /// Suspends the caller until `duration` of this clock's own time has
    /// passed. `SystemClock.sleep(for:)` really does `Task.sleep`.
    /// `TestClock.sleep(for:)` suspends until a test's `advance(by:)`
    /// reaches this call's deadline.
    nonisolated func sleep(for duration: Duration) async
}

/// The real clock. Every production construction site that takes a
/// `clock:` parameter defaults it to `SystemClock()` and never overrides it
/// — `ProcessStatusPaneContent` is reached only through
/// `SplitTree.makePane`, which constructs it as
/// `ProcessStatusPaneContent(target:tabLookup:)` with no `clock:` argument
/// at all (`SplitTree.swift`), so production genuinely relies on the
/// default, one fresh `SystemClock()` per content instance (Swift
/// re-evaluates a default argument at each call site, not a single shared
/// instance).
///
/// The default is deliberately the *real* clock, the same defaulted
/// real-value shape used elsewhere in this codebase
/// (`ProcessStatusPaneContent.samplingInterval = .seconds(1)` and
/// `coreMetricsProvider = ProcessInspector.coreMetrics` in
/// `ProcessStatusPaneContent.swift`; `ProcessGitStatusScanner
/// .teardownReapRegistry = .shared` in `GitStatusPaneContent.swift`): the
/// #0359 lesson is that a *silently-broken* default (`tabLookup = { _ in
/// nil }`, a value that quietly disables a whole feature) can hide a
/// forgotten injection — not that a default which is simply the honest,
/// correct production behavior is dangerous. A caller that never overrides
/// `clock:` in production still gets the real clock, not a clock that
/// never advances; a test that forgets to override it gets slow, real-time
/// waits it will notice immediately, not silent wrongness. Every test call
/// site still injects `TestClock` explicitly.
public nonisolated final class SystemClock: SchedulingClock, Sendable {
    public init() {}

    public var now: Date { Date() }

    public func sleep(for duration: Duration) async {
        try? await Task.sleep(for: duration)
    }
}
