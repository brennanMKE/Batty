// FootprintWarningStateTests.swift

import Foundation
import Testing
@testable import BattyKit

struct FootprintWarningPolicyTests {

    @Test func stepIsZeroBelowTheLimit() {
        let policy = FootprintWarningPolicy(limitBytes: 4_000_000_000, stepBytes: 1_000_000_000)
        #expect(policy.step(forFootprintBytes: 3_999_999_999) == 0)
    }

    @Test func stepIsOneAtExactlyTheLimit() {
        let policy = FootprintWarningPolicy(limitBytes: 4_000_000_000, stepBytes: 1_000_000_000)
        #expect(policy.step(forFootprintBytes: 4_000_000_000) == 1)
    }

    @Test func stepAdvancesByOnePerStepIncrement() {
        let policy = FootprintWarningPolicy(limitBytes: 4_000_000_000, stepBytes: 1_000_000_000)
        #expect(policy.step(forFootprintBytes: 4_999_999_999) == 1)
        #expect(policy.step(forFootprintBytes: 5_000_000_000) == 2)
        #expect(policy.step(forFootprintBytes: 6_500_000_000) == 3)
    }

    @Test func defaultStepBytesIsAQuarterOfTheLimit() {
        let policy = FootprintWarningPolicy(limitBytes: 4_000_000_000)
        #expect(policy.stepBytes == 1_000_000_000)
    }
}

/// Covers exactly the five nag-suppression cases the issue calls out: below
/// limit, first crossing, still above (no repeat), next threshold step, and
/// drop below then re-cross.
struct FootprintWarningStateTests {

    private let policy = FootprintWarningPolicy(limitBytes: 4_000_000_000, stepBytes: 1_000_000_000)

    @Test func belowLimitNeverWarns() {
        var state = FootprintWarningState()
        #expect(state.evaluate(footprintBytes: 1_000_000_000, policy: policy) == nil)
        #expect(state.evaluate(footprintBytes: 3_999_999_999, policy: policy) == nil)
    }

    @Test func firstCrossingWarnsAtStepOne() {
        var state = FootprintWarningState()
        #expect(state.evaluate(footprintBytes: 4_200_000_000, policy: policy) == 1)
    }

    @Test func stayingInTheSameStepDoesNotRepeat() {
        var state = FootprintWarningState()
        #expect(state.evaluate(footprintBytes: 4_100_000_000, policy: policy) == 1)
        #expect(state.evaluate(footprintBytes: 4_300_000_000, policy: policy) == nil)
        #expect(state.evaluate(footprintBytes: 4_900_000_000, policy: policy) == nil)
    }

    @Test func advancingToTheNextStepWarnsAgain() {
        var state = FootprintWarningState()
        #expect(state.evaluate(footprintBytes: 4_100_000_000, policy: policy) == 1)
        #expect(state.evaluate(footprintBytes: 5_200_000_000, policy: policy) == 2)
    }

    @Test func droppingBelowTheLimitThenRecrossingWarnsAgainFromStepOne() {
        var state = FootprintWarningState()
        #expect(state.evaluate(footprintBytes: 4_100_000_000, policy: policy) == 1)
        #expect(state.evaluate(footprintBytes: 3_000_000_000, policy: policy) == nil)
        #expect(state.evaluate(footprintBytes: 4_150_000_000, policy: policy) == 1)
    }

    @Test func fluctuatingBackToAnAlreadyWarnedLowerStepDoesNotRepeat() {
        var state = FootprintWarningState()
        #expect(state.evaluate(footprintBytes: 4_100_000_000, policy: policy) == 1)
        #expect(state.evaluate(footprintBytes: 5_200_000_000, policy: policy) == 2)
        // Drops back to step 1 (still above the limit, so no reset) then
        // climbs back to step 2 — already warned about, must not repeat.
        #expect(state.evaluate(footprintBytes: 4_400_000_000, policy: policy) == nil)
        #expect(state.evaluate(footprintBytes: 5_300_000_000, policy: policy) == nil)
    }

    /// Regression for the blind spot review round 1 caught: the high-water
    /// mark is stored as bytes, not a step index, precisely so raising the
    /// limit (the user's natural reaction to a warning) can't silently
    /// reinterpret an old step number under the new policy and suppress
    /// every later warning while the footprint keeps climbing.
    @Test func raisingTheLimitWhileAboveStillWarnsOnFurtherGrowth() {
        var state = FootprintWarningState()
        let originalPolicy = FootprintWarningPolicy(limitBytes: 4_000_000_000, stepBytes: 1_000_000_000)
        #expect(state.evaluate(footprintBytes: 12_000_000_000, policy: originalPolicy) == 9)

        // User raises the limit in Settings; stepBytes re-derives to a
        // quarter of the new limit.
        let raisedPolicy = FootprintWarningPolicy(limitBytes: 10_000_000_000)
        #expect(raisedPolicy.stepBytes == 2_500_000_000)

        // Same footprint, new policy: no new warning yet — nothing has
        // actually changed since the last one.
        #expect(state.evaluate(footprintBytes: 12_000_000_000, policy: raisedPolicy) == nil)

        // Footprint keeps growing past the new limit — must warn again,
        // even though the naively-recomputed old high-water step (9) would
        // never be exceeded by this smaller-stepBytes policy.
        #expect(state.evaluate(footprintBytes: 20_000_000_000, policy: raisedPolicy) == 5)
    }
}
