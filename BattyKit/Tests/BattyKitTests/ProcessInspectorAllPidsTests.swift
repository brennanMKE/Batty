// ProcessInspectorAllPidsTests.swift

import Foundation
import Testing
@testable import BattyKit

/// #0516: `proc_listallpids` cannot report "your buffer was too small" —
/// it fills what it is given and returns that count, so a saturated
/// buffer and a complete list are the same observation. These drive the
/// growth loop through `allPids(listAllPIDs:)`'s seam with a fake that
/// behaves exactly like the real call, including that ambiguity.
struct ProcessInspectorAllPidsTests {

    /// Mimics `proc_listallpids`: a probe call (null buffer) answers with
    /// the live count; a fill call writes as many pids as fit and returns
    /// how many it wrote, with no way to signal truncation.
    private final class FakeListAllPIDs {
        /// The pid count the probe reports — deliberately allowed to differ
        /// from `pids.count`, which is the whole point: the table grows
        /// between the probe and the fill.
        var probeCount: Int32
        var pids: [pid_t]
        private(set) var fillCapacities: [Int] = []
        /// The probe fails with `errno = ENOMEM`.
        var failProbe = false
        /// The 1-based fill attempt that fails with `errno = ENOMEM`.
        var failFillAttempt: Int?

        init(probeCount: Int32, pids: [pid_t]) {
            self.probeCount = probeCount
            self.pids = pids
        }

        func call(_ buffer: UnsafeMutableRawPointer?, _ bufferSize: Int32) -> Int32 {
            guard let buffer else {
                if failProbe { errno = ENOMEM; return -1 }
                return probeCount
            }
            let capacity = Int(bufferSize) / MemoryLayout<pid_t>.stride
            fillCapacities.append(capacity)
            if fillCapacities.count == failFillAttempt { errno = ENOMEM; return -1 }
            let written = min(capacity, pids.count)
            buffer.bindMemory(to: pid_t.self, capacity: capacity)
                .update(from: Array(pids.prefix(written)), count: written)
            return Int32(written)
        }
    }

    private func pids(_ count: Int) -> [pid_t] {
        (1...count).map { pid_t($0) }
    }

    @Test func aListThatFitsTheFirstBufferIsReturnedWhole() {
        let fake = FakeListAllPIDs(probeCount: 400, pids: pids(400))
        let result = ProcessInspector.allPids(listAllPIDs: fake.call)
        #expect(result == pids(400))
        #expect(fake.fillCapacities == [464])
    }

    /// The regression. The probe sees 400, the fill sees 1000 — more than
    /// the 64-slot headroom — so the first buffer saturates at 464 and
    /// returning it would silently drop 536 pids.
    @Test func aTableThatOutgrowsTheHeadroomBetweenProbeAndFillIsRetriedLarger() {
        let fake = FakeListAllPIDs(probeCount: 400, pids: pids(1000))
        let result = ProcessInspector.allPids(listAllPIDs: fake.call)
        #expect(result == pids(1000))
        #expect(fake.fillCapacities == [464, 928, 1856])
    }

    /// A list that exactly fills its buffer is indistinguishable from a
    /// truncated one, so it must be retried rather than trusted — and the
    /// retry must still return the right answer, not a doubled or empty
    /// one.
    @Test func aListThatExactlyFillsItsBufferIsRetriedAndStillCorrect() {
        let fake = FakeListAllPIDs(probeCount: 400, pids: pids(464))
        let result = ProcessInspector.allPids(listAllPIDs: fake.call)
        #expect(result == pids(464))
        #expect(fake.fillCapacities == [464, 928])
    }

    /// Growth is bounded. A table that saturates every attempt returns
    /// what it has rather than looping forever.
    @Test func aTableThatSaturatesEveryAttemptGivesUpBoundedAndReturnsWhatItHas() {
        let huge = pids(100_000)
        let fake = FakeListAllPIDs(probeCount: 400, pids: huge)
        let result = ProcessInspector.allPids(listAllPIDs: fake.call)
        #expect(fake.fillCapacities == [464, 928, 1856, 3712, 7424])
        #expect(result == Array(huge.prefix(7424)))
    }

    @Test func aProbeThatFailsIsAFailedWalkNotAnEmptyList() {
        let fake = FakeListAllPIDs(probeCount: 400, pids: pids(400))
        fake.failProbe = true
        #expect(ProcessInspector.allPids(listAllPIDs: fake.call) == nil)
        #expect(fake.fillCapacities == [])
    }

    @Test func aFillThatFailsIsAFailedWalkNotAnEmptyList() {
        let fake = FakeListAllPIDs(probeCount: 400, pids: pids(400))
        fake.failFillAttempt = 1
        #expect(ProcessInspector.allPids(listAllPIDs: fake.call) == nil)
        #expect(fake.fillCapacities == [464])
    }

    @Test func aFillThatFailsAfterAGrowthRetryReturnsNoPartialList() {
        let fake = FakeListAllPIDs(probeCount: 400, pids: pids(1000))
        fake.failFillAttempt = 2
        #expect(ProcessInspector.allPids(listAllPIDs: fake.call) == nil)
        #expect(fake.fillCapacities == [464, 928])
    }
}
