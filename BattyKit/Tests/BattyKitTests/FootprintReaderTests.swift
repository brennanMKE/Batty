// FootprintReaderTests.swift

import Darwin
import Foundation
import Testing
@testable import BattyKit

struct FootprintReaderTests {

    @Test func physFootprintBytesReturnsAPlausibleNonZeroValue() {
        guard let bytes = FootprintReader.physFootprintBytes() else {
            Issue.record("Expected a non-nil footprint reading for the current process")
            return
        }
        // Any running XCTest/swift-testing process has at least a few MB
        // resident; 200 GB is a generous ceiling well above what a test
        // host could plausibly report, catching a garbage/overflowed read.
        #expect(bytes > 1_000_000)
        #expect(bytes < 200_000_000_000)
    }

    /// The reliably-assertable version of "reads `phys_footprint`, not RSS":
    /// re-implement the same `task_info(TASK_VM_INFO)` call independently
    /// here and check `FootprintReader` returns (approximately) the same
    /// value. A unit-test process has no reliable way to force pages into
    /// the compressor, so the 7-29x RSS-vs-footprint gap from #0285's field
    /// reports can't be reproduced in-process; cross-checking against a
    /// second known-good `task_info` call is the fallback the issue calls
    /// for. A wide but bounded tolerance absorbs normal allocation churn
    /// between the two calls.
    @Test func physFootprintBytesMatchesAnIndependentTaskInfoCall() {
        func rawPhysFootprint() -> UInt64? {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(
                MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
            )
            let result = withUnsafeMutablePointer(to: &info) { pointer -> kern_return_t in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                }
            }
            guard result == KERN_SUCCESS else { return nil }
            return info.phys_footprint
        }

        guard let reference = rawPhysFootprint(), let sample = FootprintReader.physFootprintBytes() else {
            Issue.record("Expected both task_info reads to succeed")
            return
        }
        let delta = reference > sample ? reference - sample : sample - reference
        // 50 MB tolerance: generous enough to absorb allocations made by the
        // test framework between the two calls, tight enough that returning
        // an unrelated field (e.g. RSS on a process with several hundred MB
        // of compressed pages, or a stale/zeroed struct) would fail it.
        #expect(delta < 50_000_000)
    }
}
