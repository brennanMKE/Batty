// PendingTeardownReapRegistryTests.swift

import Darwin
import Foundation
import Testing
@testable import BattyKit

/// Covers `PendingTeardownReapRegistry` in isolation — #0425's process-wide
/// drain point for a subprocess reap left behind by content already outside
/// the model tree. `LMStudioDashboardWiringTests` and
/// `ProcessGitStatusScannerTests` cover the two production conformers
/// actually registering into it; these tests exercise the registry's own
/// register/deregister/drain contract against a real subprocess so a
/// mistake here can't hide behind either conformer's own bookkeeping.
///
/// Every test constructs its own `PendingTeardownReapRegistry()` instance
/// rather than touching `.shared` — the singleton is process-wide, and
/// Swift Testing can run these in parallel with unrelated suites that also
/// touch `.shared` (the real conformers' default).
struct PendingTeardownReapRegistryTests {

    // MARK: - Fixture

    /// A single-process (no forked grandchild — `exec` replaces the shell)
    /// child that ignores `SIGTERM` once it has actually installed the
    /// trap. `echo ready` before the `exec`, with stdout on a `Pipe` the
    /// caller blocks on, closes the race #0424 describes: without it, a
    /// test could send `SIGTERM` before `sh` finished parsing
    /// `trap '' TERM`, in which case the child dies on the plain signal and
    /// every assertion about ignoring `SIGTERM` passes vacuously.
    private static func makeStubbornProcess() -> (process: Process, readyPipe: Pipe) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "trap '' TERM; echo ready; exec sleep 60"]
        let readyPipe = Pipe()
        process.standardOutput = readyPipe
        process.standardError = Pipe()
        return (process, readyPipe)
    }

    /// Blocks until the child's readiness line arrives — i.e. until
    /// `trap '' TERM` has actually run, not merely until `Process.run()`
    /// returned (which only proves `fork`/`exec` was requested).
    private static func waitForReady(_ pipe: Pipe) {
        _ = pipe.fileHandleForReading.availableData
    }

    // MARK: - register / deregister

    @Test func registerThenDeregisterLeavesNothingPending() throws {
        let registry = PendingTeardownReapRegistry()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["60"]
        try process.run()
        defer { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }

        let token = registry.register(process: process, label: "test", bound: 5)
        #expect(registry.pendingCountForTesting == 1)

        registry.deregister(token)
        #expect(registry.pendingCountForTesting == 0)

        process.terminate()
    }

    @Test func deregisteringAnUnknownTokenIsANoOp() {
        let registry = PendingTeardownReapRegistry()
        registry.deregister(UUID())
        #expect(registry.pendingCountForTesting == 0)
    }

    @Test func drainSynchronouslyIsANoOpWhenNothingIsPending() {
        let registry = PendingTeardownReapRegistry()
        registry.drainSynchronously()
        #expect(registry.pendingCountForTesting == 0)
    }

    // MARK: - drainSynchronously actually reaps

    /// The core #0425 guarantee, at the registry's own level: a process
    /// registered but never reaped by anything else is still dead, and
    /// removed from the registry, once `drainSynchronously()` returns —
    /// `SIGTERM` alone does not kill this fixture; only the `SIGKILL`
    /// escalation `drainSynchronously()` runs internally does.
    @Test func drainSynchronouslyKillsAndReapsARegisteredSigtermIgnoringProcess() throws {
        let registry = PendingTeardownReapRegistry()
        let (process, readyPipe) = Self.makeStubbornProcess()
        try process.run()
        Self.waitForReady(readyPipe)
        let pid = process.processIdentifier
        defer { if process.isRunning { kill(pid, SIGKILL) } }

        process.terminate()
        #expect(process.isRunning, "sanity check: the child must still be alive immediately after SIGTERM, or this isn't exercising the ignore-SIGTERM path")

        registry.register(process: process, label: "stubborn", bound: 0.2)
        registry.drainSynchronously()

        #expect(!process.isRunning, "drainSynchronously() must SIGKILL a process that ignored SIGTERM")
        #expect(registry.pendingCountForTesting == 0)

        // No orphan: confirm the OS has actually reaped the pid, not just
        // that `Process.isRunning` (a Foundation-side flag) flipped.
        var killResult: Int32 = 0
        for _ in 0..<50 {
            killResult = kill(pid, 0)
            if killResult != 0 { break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        #expect(killResult != 0, "pid \(pid) must not still be signalable after drainSynchronously() — orphaned process")
    }

    @Test func drainSynchronouslyReapsEveryRegisteredEntryIndependently() throws {
        let registry = PendingTeardownReapRegistry()
        let fixtures = [Self.makeStubbornProcess(), Self.makeStubbornProcess()]
        for (process, readyPipe) in fixtures {
            try process.run()
            Self.waitForReady(readyPipe)
        }
        defer {
            for (process, _) in fixtures where process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }

        for (index, entry) in fixtures.enumerated() {
            entry.process.terminate()
            registry.register(process: entry.process, label: "stubborn-\(index)", bound: 0.2)
        }
        #expect(registry.pendingCountForTesting == 2)

        registry.drainSynchronously()

        for (process, _) in fixtures {
            #expect(!process.isRunning)
        }
        #expect(registry.pendingCountForTesting == 0)
    }
}
