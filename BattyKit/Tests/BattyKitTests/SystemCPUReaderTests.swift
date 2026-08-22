// SystemCPUReaderTests.swift

import Testing
@testable import BattyKit

struct SystemCPUReaderTests {

    @Test func currentTicksReturnsAtLeastOneCore() {
        let cores = SystemCPUReader.currentTicks()
        #expect(!cores.isEmpty)
    }

    @Test func percentagesIsNilWhenShapesDontMatch() {
        let one = [CoreTicks(user: 0, system: 0, idle: 0, nice: 0)]
        let two = [CoreTicks(user: 0, system: 0, idle: 0, nice: 0), CoreTicks(user: 0, system: 0, idle: 0, nice: 0)]
        #expect(SystemCPUReader.percentages(from: one, to: two) == nil)
    }

    @Test func percentagesComputesBusyFractionOfTotalDelta() throws {
        let previous = [CoreTicks(user: 0, system: 0, idle: 0, nice: 0)]
        let current = [CoreTicks(user: 50, system: 0, idle: 50, nice: 0)]
        let percentages = try #require(SystemCPUReader.percentages(from: previous, to: current))
        #expect(percentages == [50.0])
    }

    @Test func percentagesIsZeroWhenNoTimeHasPassed() throws {
        let ticks = [CoreTicks(user: 10, system: 10, idle: 10, nice: 0)]
        let percentages = try #require(SystemCPUReader.percentages(from: ticks, to: ticks))
        #expect(percentages == [0.0])
    }
}

struct CoreCPUDeltaTrackerTests {

    @Test func firstCallHasNoBaselineAndReturnsNil() {
        var tracker = CoreCPUDeltaTracker()
        #expect(tracker.percentages(for: [CoreTicks(user: 0, system: 0, idle: 0, nice: 0)]) == nil)
    }

    @Test func secondCallComputesAPercentageAgainstTheFirst() throws {
        var tracker = CoreCPUDeltaTracker()
        _ = tracker.percentages(for: [CoreTicks(user: 0, system: 0, idle: 0, nice: 0)])
        let result = tracker.percentages(for: [CoreTicks(user: 25, system: 0, idle: 75, nice: 0)])
        let percentages = try #require(result)
        #expect(percentages == [25.0])
    }

    @Test func resetDropsTheBaseline() {
        var tracker = CoreCPUDeltaTracker()
        _ = tracker.percentages(for: [CoreTicks(user: 0, system: 0, idle: 0, nice: 0)])
        tracker.reset()
        #expect(tracker.percentages(for: [CoreTicks(user: 25, system: 0, idle: 75, nice: 0)]) == nil)
    }
}
