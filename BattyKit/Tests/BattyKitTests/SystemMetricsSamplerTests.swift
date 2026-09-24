// SystemMetricsSamplerTests.swift

import Testing
@testable import BattyKit

/// Regression pin for review round 1's finding #2: the first `sampleOnce()`
/// call (no CPU delta baseline yet) must report `aggregatePercent == nil`
/// and a real `coreCount`, never a fabricated `0.0%` / `0 cores` that reads
/// as a plausible measurement on a busy machine.
struct SystemMetricsSamplerCPUAvailabilityTests {

    @Test func firstSampleHasNoCPUAggregateYetButReportsARealCoreCount() async {
        let sampler = SystemMetricsSampler()
        let first = await sampler.sampleOnce()

        #expect(first.cpu.aggregatePercent == nil)
        #expect(first.cpu.perCorePercent == nil)
        // coreCount comes from the raw tick read, not from
        // perCorePercent?.count, so it must be a real number (every Mac
        // this suite runs on has at least one core) even on this same
        // no-baseline tick.
        #expect(first.cpu.coreCount > 0)
    }

    @Test func secondSampleHasARealCPUAggregate() async {
        let sampler = SystemMetricsSampler()
        _ = await sampler.sampleOnce()
        let second = await sampler.sampleOnce()

        #expect(second.cpu.aggregatePercent != nil)
        #expect(second.cpu.perCorePercent != nil)
        #expect(second.cpu.perCorePercent?.count == second.cpu.coreCount)
    }

    @Test func everySampleReportsANonNilSampledAt() async {
        let sampler = SystemMetricsSampler()
        let snapshot = await sampler.sampleOnce()
        #expect(snapshot.sampledAt != nil)
    }
}
