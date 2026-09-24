// SystemCPUReaderTests.swift

import Testing
@testable import BattyKit

struct SystemCPUReaderTests {

    @Test func currentTicksReturnsAtLeastOneCore() {
        var failureGate = FailureLogGate<CPUReadFailure>()
        let cores = SystemCPUReader.currentTicks(failureGate: &failureGate)
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

    @Test func parseCoreTicksParsesAWellFormedBuffer() throws {
        // CPU_STATE_MAX is 4, ordered USER, SYSTEM, IDLE, NICE.
        let rawTicks: [Int32] = [
            10, 20, 30, 40,
            1, 2, 3, 4,
        ]
        let cores = try #require(SystemCPUReader.parseCoreTicks(numCpus: 2, rawTicks: rawTicks))
        #expect(cores == [
            CoreTicks(user: 10, system: 20, idle: 30, nice: 40),
            CoreTicks(user: 1, system: 2, idle: 3, nice: 4),
        ])
    }

    @Test func parseCoreTicksFailsWhenBufferIsShorterThanNumCpusTimesStateMax() {
        // Claims 2 cores but only supplies enough integers for one
        // (#0352 — the kernel-reported counts can disagree).
        let rawTicks: [Int32] = [10, 20, 30, 40]
        #expect(SystemCPUReader.parseCoreTicks(numCpus: 2, rawTicks: rawTicks) == nil)
    }

    @Test func parseCoreTicksFailsWhenNumCpusIsZero() {
        #expect(SystemCPUReader.parseCoreTicks(numCpus: 0, rawTicks: []) == nil)
    }

    @Test func parseCoreTicksFailsWhenNumCpusIsNegative() {
        let rawTicks: [Int32] = [10, 20, 30, 40]
        #expect(SystemCPUReader.parseCoreTicks(numCpus: -1, rawTicks: rawTicks) == nil)
    }

    @Test func parseCoreTicksAcceptsAnExactlySizedBuffer() throws {
        let rawTicks: [Int32] = [1, 2, 3, 4]
        let cores = try #require(SystemCPUReader.parseCoreTicks(numCpus: 1, rawTicks: rawTicks))
        #expect(cores == [CoreTicks(user: 1, system: 2, idle: 3, nice: 4)])
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
