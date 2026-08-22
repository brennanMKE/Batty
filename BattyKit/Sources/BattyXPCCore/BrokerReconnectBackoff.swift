// BrokerReconnectBackoff.swift

import Foundation

/// Exponential backoff schedule for `AppXPCCoordinator`'s self-healing retry
/// once `BrokerReconnectBudget` exhausts its burst of attempts (#0361) — the
/// gap that previously left a process permanently unregistered with the
/// broker, with no path back short of relaunching the app. Doubling from
/// `base`, capped at `cap`: retries spread further apart on their own (never
/// a tight loop), but never stop altogether once capped either — a broker
/// that is down for a while still gets tried again every `cap` seconds,
/// indefinitely, until one succeeds.
///
/// Kept as a pure function of the attempt index, with no `Timer` or
/// `DispatchQueue` involved, so the schedule itself is unit-testable;
/// `AppXPCCoordinator` is the only caller that turns an interval into a real
/// scheduled retry.
public nonisolated enum BrokerReconnectBackoff {
    public static func interval(forAttempt attempt: Int, base: TimeInterval = 5, cap: TimeInterval = 60) -> TimeInterval {
        precondition(attempt >= 0, "attempt must not be negative")
        guard attempt > 0 else { return min(base, cap) }
        let scaled = base * pow(2, Double(attempt))
        return min(scaled, cap)
    }
}
