// BrokerReconnectBackoffTests.swift

import Testing
@testable import BattyKit

/// Covers the self-healing backoff schedule `AppXPCCoordinator` uses once
/// `BrokerReconnectBudget` exhausts its burst of attempts (#0361) — the
/// regression guard against a process that is dead to the broker forever
/// with no path back short of a relaunch. No `Timer`/`DispatchQueue`
/// involved: the schedule is a pure function of the attempt index.
struct BrokerReconnectBackoffTests {

    @Test func firstAttemptUsesTheBaseInterval() {
        #expect(BrokerReconnectBackoff.interval(forAttempt: 0, base: 5, cap: 60) == 5)
    }

    @Test func intervalsGrowWithEachAttempt() {
        // The property that matters for "never retry hot": each attempt is
        // strictly farther out than the last, up to the cap.
        let intervals = (0..<5).map { BrokerReconnectBackoff.interval(forAttempt: $0, base: 5, cap: 60) }
        #expect(intervals == [5, 10, 20, 40, 60])
    }

    @Test func intervalNeverExceedsTheCap() {
        for attempt in 0..<20 {
            #expect(BrokerReconnectBackoff.interval(forAttempt: attempt, base: 5, cap: 60) <= 60)
        }
    }

    @Test func staysAtTheCapOnceReached() {
        // The property that matters for "never give up": retries keep
        // happening at the capped cadence forever, rather than the schedule
        // eventually producing an ever-growing (or infinite) gap.
        #expect(BrokerReconnectBackoff.interval(forAttempt: 10, base: 5, cap: 60) == 60)
        #expect(BrokerReconnectBackoff.interval(forAttempt: 100, base: 5, cap: 60) == 60)
    }

    @Test func respectsCustomBaseAndCap() {
        #expect(BrokerReconnectBackoff.interval(forAttempt: 0, base: 1, cap: 4) == 1)
        #expect(BrokerReconnectBackoff.interval(forAttempt: 1, base: 1, cap: 4) == 2)
        #expect(BrokerReconnectBackoff.interval(forAttempt: 2, base: 1, cap: 4) == 4)
        #expect(BrokerReconnectBackoff.interval(forAttempt: 3, base: 1, cap: 4) == 4)
    }

    @Test func defaultsMatchTheDocumentedSchedule() {
        #expect(BrokerReconnectBackoff.interval(forAttempt: 0) == 5)
        #expect(BrokerReconnectBackoff.interval(forAttempt: 4) == 60)
    }
}
