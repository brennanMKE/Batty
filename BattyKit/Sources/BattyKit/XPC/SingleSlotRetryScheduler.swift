// SingleSlotRetryScheduler.swift

/// Guarantees at most one deferred action is pending at a time: scheduling a
/// new one (`replace(with:)`) cancels whatever was previously pending first.
/// Backs `AppXPCCoordinator`'s self-healing backoff retry (#0361) — several
/// broker give-up events arriving in quick succession (repeated
/// interruption/invalidation signals, a repeated `SMAppService` repair
/// failure) must schedule exactly one pending reconnect attempt, never one
/// per event, or the coordinator would end up with multiple overlapping
/// `connectToBroker` calls racing each other.
///
/// Generic over the scheduled handle type (`DispatchWorkItem` in
/// production) with no `Dispatch`/`Timer` involved here at all, so the
/// "replacing cancels the old one" invariant is unit-testable with a plain
/// value type standing in for a handle.
public final class SingleSlotRetryScheduler<Handle> {
    private var pending: Handle?
    private let cancel: (Handle) -> Void

    public init(cancel: @escaping (Handle) -> Void) {
        self.cancel = cancel
    }

    /// Explicit, empty deinit — workaround for #0391. The implicit deinit
    /// crashes swift-frontend 6.3.3's SIL EarlyPerfInliner at `-O`
    /// (`SILFunctionTransform "EarlyPerfInliner" on @$s8BattyKit24SingleSlotRetrySchedulerCfD`),
    /// which otherwise blocks every Release build of the app. Simply writing
    /// an explicit deinit — even an empty one — sidesteps whatever about the
    /// synthesized one trips the inliner. This is a defect in swift-frontend,
    /// not in this class.
    ///
    /// Safe to remove once the project's toolchain moves past Swift 6.3.3 —
    /// delete this `deinit` and confirm `./build.sh release archive
    /// -configuration Release` still succeeds.
    ///
    /// The body MUST stay empty. Calling `clear()` here would cancel the
    /// pending handle on deallocation — a real behavior change rather than
    /// a compiler workaround; it must be its own decision.
    deinit {}

    /// `true` while an action is genuinely still going to happen — cleared
    /// both by `clear()`/`replace(with:)` cancelling the handle and by
    /// `markFired()` reporting that it already ran.
    public var hasPending: Bool { pending != nil }

    /// Cancels any previously pending handle, then stores `handle` as the
    /// new pending one.
    public func replace(with handle: Handle) {
        if let pending {
            cancel(pending)
        }
        pending = handle
    }

    /// Cancels the pending handle, if any, and clears the slot. Idempotent.
    public func clear() {
        if let pending {
            cancel(pending)
        }
        pending = nil
    }

    /// Reports that the pending handle has already run, clearing the slot
    /// without calling `cancel` on it. Callers invoke this from the handle's
    /// own execution, before doing anything else, so `hasPending` never
    /// reports a stale `true` for a handle that already fired, and a later
    /// `clear()`/`replace(with:)` doesn't attempt to cancel it. No identity
    /// check against `pending` is needed: a handle superseded by
    /// `replace(with:)` is always cancelled before it can run, since both
    /// happen on the same main serial queue.
    public func markFired() {
        pending = nil
    }
}
