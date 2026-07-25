// BoundedPollTests.swift

import BattyXPCCore
import Foundation
import Testing
@testable import BattyKit

/// Tests the load-bearing bound/retry logic behind the CLI's connect dance
/// (#0271) with plain closures — no listener, no connection, no broker. All
/// `sleep` closures are no-ops so these tests run at unit-test speed
/// regardless of `interval`.
struct BoundedPollTests {

    @Test func returnsFirstNonNilValueWithoutExhaustingAttempts() {
        var callCount = 0
        let result = BoundedPoll.poll(maxAttempts: 5, interval: 0.25, sleep: { _ in }) { () -> Int? in
            callCount += 1
            return callCount == 1 ? 99 : nil
        }
        #expect(result == 99)
        #expect(callCount == 1)
    }

    @Test func nilThenValueSequenceSucceeds() {
        var callCount = 0
        let result = BoundedPoll.poll(maxAttempts: 5, interval: 0.25, sleep: { _ in }) { () -> Int? in
            callCount += 1
            return callCount < 3 ? nil : 42
        }
        #expect(result == 42)
        #expect(callCount == 3)
    }

    @Test func alwaysNilSequenceFailsInBoundedTime() {
        var callCount = 0
        let result = BoundedPoll.poll(maxAttempts: 4, interval: 0.25, sleep: { _ in }) { () -> Int? in
            callCount += 1
            return nil
        }
        #expect(result == nil)
        // Exactly maxAttempts calls, not zero and not unbounded — this is
        // the regression guard for "without the bound, a broken app hangs
        // the CLI forever."
        #expect(callCount == 4)
    }

    @Test func sleepsBetweenAttemptsButNotAfterTheLastOne() {
        var sleepCount = 0
        _ = BoundedPoll.poll(maxAttempts: 3, interval: 0.1, sleep: { _ in sleepCount += 1 }) { () -> Int? in
            nil
        }
        #expect(sleepCount == 2)
    }

    @Test func passesTheConfiguredIntervalToSleep() {
        var observedIntervals: [TimeInterval] = []
        _ = BoundedPoll.poll(maxAttempts: 3, interval: 0.42, sleep: { observedIntervals.append($0) }) { () -> Int? in
            nil
        }
        #expect(observedIntervals == [0.42, 0.42])
    }

    @Test func singleAttemptNeverSleeps() {
        var sleepCalled = false
        let result = BoundedPoll.poll(maxAttempts: 1, interval: 10, sleep: { _ in sleepCalled = true }) { () -> Int? in
            nil
        }
        #expect(result == nil)
        #expect(!sleepCalled)
    }
}
