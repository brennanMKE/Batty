// ProcessCPUDeltaTrackerTests.swift

import Foundation
import Testing
@testable import BattyKit

struct ProcessCPUDeltaTrackerTests {
    private func sample(pid: pid_t, user: UInt64?, system: UInt64?) -> ProcessSample {
        ProcessSample(
            pid: pid,
            name: "test",
            path: nil,
            threadCount: 1,
            physFootprintBytes: user == nil ? nil : 1_000_000,
            residentSizeBytes: nil,
            cpuTicksUser: user,
            cpuTicksSystem: system
        )
    }

    @Test func firstTickHasNoBaselineForAnyPid() {
        var tracker = ProcessCPUDeltaTracker()
        let percentages = tracker.percentages(for: [sample(pid: 1, user: 1000, system: 0)])
        #expect(percentages.isEmpty)
    }

    @Test func secondTickComputesAPercentageFromTheTickDelta() throws {
        var tracker = ProcessCPUDeltaTracker()
        let start = Date()
        // One second of ticks fully busy: delta ticks converted to
        // nanoseconds via MachTimebase should read close to 100%.
        let ticksPerSecond = UInt64(1_000_000_000 / MachTimebase.nanosecondsPerTick)

        _ = tracker.percentages(for: [sample(pid: 1, user: 0, system: 0)], at: start)
        let percentages = tracker.percentages(
            for: [sample(pid: 1, user: ticksPerSecond, system: 0)],
            at: start.addingTimeInterval(1)
        )

        let percent = try #require(percentages[1])
        #expect(percent > 90)
        #expect(percent < 110)
    }

    @Test func ownershipDeniedRowsNeverProduceAPercentage() {
        var tracker = ProcessCPUDeltaTracker()
        let start = Date()
        _ = tracker.percentages(for: [sample(pid: 1, user: nil, system: nil)], at: start)
        let percentages = tracker.percentages(for: [sample(pid: 1, user: nil, system: nil)], at: start.addingTimeInterval(1))
        #expect(percentages[1] == nil)
    }

    @Test func aPidMissingFromTheNextSampleIsDroppedFromTheBaseline() {
        var tracker = ProcessCPUDeltaTracker()
        let start = Date()
        _ = tracker.percentages(for: [sample(pid: 1, user: 0, system: 0), sample(pid: 2, user: 0, system: 0)], at: start)
        // pid 2 exited; only pid 1 reappears.
        let percentages = tracker.percentages(for: [sample(pid: 1, user: 0, system: 0)], at: start.addingTimeInterval(1))
        #expect(percentages[2] == nil)
    }

    @Test func resetDropsEveryBaseline() {
        var tracker = ProcessCPUDeltaTracker()
        let start = Date()
        _ = tracker.percentages(for: [sample(pid: 1, user: 0, system: 0)], at: start)
        tracker.reset()
        let percentages = tracker.percentages(for: [sample(pid: 1, user: 1000, system: 0)], at: start.addingTimeInterval(1))
        // No baseline survived the reset, so this is treated as a first tick.
        #expect(percentages[1] == nil)
    }
}
