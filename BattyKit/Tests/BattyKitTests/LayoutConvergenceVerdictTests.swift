// LayoutConvergenceVerdictTests.swift

import Testing
@testable import BattyKit

/// The probe's verdicts as pure values: a clean settle passes however many
/// rounds it took, and a request ceiling passes on a strict majority of
/// samples.
@MainActor
struct LayoutConvergenceVerdictTests {

    private func result(rounds: Int, brokeLoop: Bool = false, dirtyViews: [String] = []) -> SettleResult {
        SettleResult(
            rounds: rounds,
            rootPasses: 8,
            windowUpdateConstraintsCalls: 19,
            postNeedsUpdateConstraintsCalls: 658,
            postNeedsLayoutCalls: 7,
            brokeLoop: brokeLoop,
            dirtyViews: dirtyViews
        )
    }

    @Test func lateCleanSettleIsConverged() {
        let late = result(rounds: LayoutConvergenceProbe.calibratedRoundBound + 1)
        #expect(late.outcome == .settledLate)
        #expect(late.converged)
    }

    @Test func settleStillDirtyAtTheHangGuardDidNotConverge() {
        let stuck = result(rounds: LayoutConvergenceProbe.maxRounds + 1, dirtyViews: ["X"])
        #expect(stuck.outcome == .didNotConverge)
        #expect(!stuck.converged)
    }

    @Test func breakerTripDidNotConvergeEvenWhenClean() {
        let broke = result(rounds: 1, brokeLoop: true)
        #expect(broke.outcome == .didNotConverge)
        #expect(!broke.converged)
    }

    @Test func oneRoundSettleIsSettled() {
        let settled = result(rounds: 1)
        #expect(settled.outcome == .settled)
        #expect(settled.converged)
        #expect(settled.description.hasPrefix("outcome=settled "))
    }

    @Test func oneSpikeAmongSixTicksIsWithinBudget() {
        #expect(LayoutConvergenceProbe.mostlyWithin([25, 35, 25, 25, 25, 25], ceiling: 30))
    }

    @Test func everyTickOverIsOverBudget() {
        #expect(!LayoutConvergenceProbe.mostlyWithin([57, 57, 57, 57, 57, 57], ceiling: 30))
    }

    @Test func exactlyHalfOverIsOverBudget() {
        #expect(!LayoutConvergenceProbe.mostlyWithin([25, 25, 25, 35, 35, 35], ceiling: 30))
    }

    @Test func noSamplesIsOverBudget() {
        #expect(!LayoutConvergenceProbe.mostlyWithin([], ceiling: 30))
    }

    @Test func budgetReportListsEverySample() {
        #expect(LayoutConvergenceProbe.budgetReport([25, 35, 25], ceiling: 30) == "1 of 3 over 30 (max 35): [25, 35, 25]")
    }
}
