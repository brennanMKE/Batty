// BrokerReconnectBudget.swift

/// Caps the automatic broker-reconnect attempts `AppXPCCoordinator` makes in
/// response to `interruptionHandler`/`invalidationHandler` firing (#0272
/// items 1–2), so a broker that is genuinely and permanently gone produces a
/// bounded burst of retries rather than a tight reconnect loop that never
/// settles — `NSXPCConnection(machServiceName:)` against a name launchd
/// doesn't own can interrupt or invalidate almost immediately, and without a
/// cap each failure would immediately trigger another connection attempt.
///
/// Distinct from `BrokerRepairGuard`: that type bounds the rate of
/// `SMAppService.unregister()`/`register()` calls (a heavier, once-per-launch
/// operation); this type bounds the rate of `NSXPCConnection` rebuilds (a
/// lighter operation that is expected to happen more than once across a
/// launch — e.g. once per genuine broker restart).
///
/// `reset()` is called on a confirmed registration (the broker actually
/// answered `brokerPing`): a live broker again means the environment
/// recovered, and a *future* interruption/invalidation deserves a full
/// budget rather than inheriting exhaustion from an earlier, unrelated
/// outage.
public final class BrokerReconnectBudget {
    private let maxAttempts: Int
    public private(set) var remaining: Int

    public init(maxAttempts: Int = 5) {
        precondition(maxAttempts > 0, "maxAttempts must be positive")
        self.maxAttempts = maxAttempts
        self.remaining = maxAttempts
    }

    /// Returns `true` and decrements `remaining` if a reconnect attempt is
    /// still within budget; returns `false` without decrementing once the
    /// budget is exhausted.
    @discardableResult
    public func consumeAttempt() -> Bool {
        guard remaining > 0 else { return false }
        remaining -= 1
        return true
    }

    /// Restores the full budget. Call on a confirmed registration.
    public func reset() {
        remaining = maxAttempts
    }
}
