// ProcessMetricsReaderTests.swift

import Darwin
import Foundation
import Testing
@testable import BattyKit

struct ProcessMetricsReaderTests {

    @Test func sampleOfOwnPidReturnsPlausibleValues() {
        guard let sample = ProcessMetricsReader.sample(pid: getpid()) else {
            Issue.record("Expected a non-nil sample for the current process")
            return
        }
        #expect(sample.pid == getpid())
        #expect(!sample.name.isEmpty)
        #expect(sample.cpuTicksUser != nil)
        #expect(sample.cpuTicksSystem != nil)
        // A live test process reports a real footprint via proc_pid_rusage
        // the same way FootprintReaderTests checks task_info directly.
        #expect(sample.physFootprintBytes != nil)
        #expect((sample.physFootprintBytes ?? 0) > 0)
        #expect(sample.isOwnershipDenied == false)
    }

    @Test func sampleOfANonexistentPidReturnsNil() {
        // A pid this large is exceedingly unlikely to be live on any
        // machine (pid_t wraps at PID_MAX, 99998 on Darwin); ESRCH is the
        // expected outcome this asserts on.
        let bogus: pid_t = 999_999
        #expect(ProcessMetricsReader.sample(pid: bogus) == nil)
    }

    @Test func sampleOfPidZeroIsTheHardcodedKernelTaskFallback() {
        let sample = ProcessMetricsReader.sample(pid: 0)
        #expect(sample?.name == "kernel_task")
        #expect(sample?.cpuTicksUser == nil)
        #expect(sample?.physFootprintBytes == nil)
    }

    @Test func sampleAllIncludesTheCurrentProcess() {
        var failureGate = FailureLogGate<ProcessListFailure>()
        let samples = ProcessMetricsReader.sampleAll(failureGate: &failureGate)
        #expect(!samples.isEmpty)
        #expect(samples.contains { $0.pid == getpid() })
    }

    /// Regression pin for a review round 1 finding (#0314, escalated by
    /// #0305's own reviewer running this exact code): `listAllPIDs()`
    /// originally divided `proc_listallpids`'s filled-buffer return by
    /// `MemoryLayout<pid_t>.size`, treating a pid *count* as if it were a
    /// byte count — silently enumerating roughly 1/12th of the machine's
    /// real process count (62 of 716, independently reproduced). A
    /// "non-empty" assertion alone would never have caught this; the fix
    /// is checked against a second, independent `proc_listallpids` call
    /// built directly in this test (deliberately not sharing
    /// `ProcessMetricsReader`'s own implementation), the same
    /// cross-check-with-a-second-call pattern `FootprintReaderTests` uses
    /// for `phys_footprint`.
    @Test func sampleAllCountIsNotSilentlyTruncated() {
        var pids = [pid_t](repeating: 0, count: 8192)
        let capacityBytes = Int32(pids.count * MemoryLayout<pid_t>.stride)
        let independentCount = proc_listallpids(&pids, capacityBytes)
        guard independentCount > 0 else {
            Issue.record("Expected the independent proc_listallpids call to succeed")
            return
        }

        var failureGate = FailureLogGate<ProcessListFailure>()
        let sampledCount = ProcessMetricsReader.sampleAll(failureGate: &failureGate).count

        // Generous slack for process churn between the two enumeration
        // calls (a process can exit or spawn in between) — 20% is far
        // looser than needed for a real regression (the bug this pins
        // produced roughly a 12x undercount) but tight enough that a
        // reintroduced /4-style bug, or a buffer overflow silently
        // dropping most pids, still fails it.
        let independent = Double(independentCount)
        let sampled = Double(sampledCount)
        #expect(sampled > independent * 0.8)
        #expect(sampled < independent * 1.2)
    }
}
