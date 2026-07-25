// BrokerRepairGuardTests.swift

import Testing
@testable import BattyKit

/// Covers the once-per-launch state machine behind the `SMAppService`
/// repair path (#0272 item 7) — no `SMAppService` involved, since
/// `BrokerRepairGuard` is pure state deliberately kept independent of it.
@MainActor
struct BrokerRepairGuardTests {

    @Test func firstAttemptSucceeds() {
        let guardObject = BrokerRepairGuard()
        #expect(!guardObject.hasAttempted)
        #expect(guardObject.attemptRepair())
        #expect(guardObject.hasAttempted)
    }

    @Test func secondAttemptThisLaunchIsRefused() {
        let guardObject = BrokerRepairGuard()
        #expect(guardObject.attemptRepair())
        #expect(!guardObject.attemptRepair())
    }

    @Test func repeatedAttemptsAfterTheFirstAreAllRefused() {
        // Not just "the second is refused" — every subsequent call this
        // launch must be, or a caller that retries on every failed call
        // (exactly the scenario this guard exists to prevent) would slip
        // through after enough failures.
        let guardObject = BrokerRepairGuard()
        #expect(guardObject.attemptRepair())
        for _ in 0..<10 {
            #expect(!guardObject.attemptRepair())
        }
    }

    @Test func aFreshInstanceHasAFullBudgetAgain() {
        // Models "once per launch": a new launch constructs a new
        // `AppXPCCoordinator`, and therefore a new guard by default.
        let first = BrokerRepairGuard()
        #expect(first.attemptRepair())
        let second = BrokerRepairGuard()
        #expect(second.attemptRepair())
    }
}
