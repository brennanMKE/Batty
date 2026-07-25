// BrokerReconnectBudgetTests.swift

import Testing
@testable import BattyKit

/// Covers the bounded automatic-reconnect budget (#0272 items 1–2) — the
/// regression guard against a genuinely, permanently absent broker turning
/// `AppXPCCoordinator`'s interruption/invalidation dispatch into a tight
/// reconnect loop. No `NSXPCConnection` involved.
@MainActor
struct BrokerReconnectBudgetTests {

    @Test func allowsExactlyMaxAttemptsThenRefuses() {
        let budget = BrokerReconnectBudget(maxAttempts: 3)
        #expect(budget.consumeAttempt())
        #expect(budget.consumeAttempt())
        #expect(budget.consumeAttempt())
        #expect(!budget.consumeAttempt())
    }

    @Test func exhaustionIsBoundedNotUnbounded() {
        // The property that matters: repeatedly calling past exhaustion
        // never starts succeeding again on its own — this is what makes a
        // permanently absent broker produce a bounded burst, not a loop
        // that never settles.
        let budget = BrokerReconnectBudget(maxAttempts: 2)
        _ = budget.consumeAttempt()
        _ = budget.consumeAttempt()
        for _ in 0..<20 {
            #expect(!budget.consumeAttempt())
        }
    }

    @Test func remainingDecrementsWithEachConsumedAttempt() {
        let budget = BrokerReconnectBudget(maxAttempts: 5)
        #expect(budget.remaining == 5)
        _ = budget.consumeAttempt()
        #expect(budget.remaining == 4)
        _ = budget.consumeAttempt()
        #expect(budget.remaining == 3)
    }

    @Test func resetRestoresTheFullBudget() {
        // Models "a confirmed registration restores the budget": a live
        // broker again means a *future* outage deserves a fresh burst of
        // retries, not one inherited from an earlier, unrelated outage.
        let budget = BrokerReconnectBudget(maxAttempts: 2)
        _ = budget.consumeAttempt()
        _ = budget.consumeAttempt()
        #expect(!budget.consumeAttempt())
        budget.reset()
        #expect(budget.remaining == 2)
        #expect(budget.consumeAttempt())
    }

    @Test func defaultBudgetIsFive() {
        let budget = BrokerReconnectBudget()
        #expect(budget.remaining == 5)
    }
}
