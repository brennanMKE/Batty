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

    /// `true` while a handle is pending.
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
}
