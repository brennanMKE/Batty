// ChildProcessFixture.swift

import Darwin
import Foundation
@testable import BattyKit

/// Owns a batch of test-spawned child processes end-to-end: track → run →
/// guaranteed `SIGKILL` + reap (#0441). A caller registers a `defer` once,
/// before running anything:
///
/// ```swift
/// let fixture = ChildProcessFixture()
/// defer { fixture.killAndReapAll() }
/// try fixture.run(processA)
/// try fixture.run(processB)
/// ```
///
/// `run(_:)` tracks `process` *before* calling `Process.run()` on it, so a
/// throwing `run()` on a later process can never skip an earlier process's
/// cleanup — the exact leak #0441 found in tests that called `try
/// processA.run(); try processB.run()` before registering any `defer` at
/// all: if `processB.run()` threw, `processA` was left running with nothing
/// left to kill it. Tracking a process whose own `run()` then throws is
/// harmless: `killAndReapAll()` skips anything that never started running.
///
/// Replaces the identical file-private `killAndReap(_:)` helpers duplicated
/// in `LMStudioDashboardPaneContentTests.swift` and
/// `LMStudioDashboardWiringTests.swift`, and the ad-hoc
/// `defer { if process.isRunning { kill(pid, SIGKILL) } }` pattern
/// duplicated across `PendingTeardownReapRegistryTests`.
///
/// `nonisolated` and lock-guarded, so a `nonisolated` test can own one and
/// block on reaping off the main actor.
nonisolated final class ChildProcessFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var processes: [Process] = []

    init() {
        SignalAudit.ensureInstalled()
    }

    /// Tracks `process` for cleanup, then runs it. Installs a
    /// `terminationHandler` (chaining any the caller set) that records how the
    /// child ended, for `deathReport(for:)`.
    func run(_ process: Process) throws {
        lock.withLock { processes.append(process) }
        let key = ObjectIdentifier(process)
        let chained = process.terminationHandler
        process.terminationHandler = { ended in
            SpawnedProcessRegistry.markReaped(ended.processIdentifier)
            DeathRecords.record(key, reason: ended.terminationReason, status: ended.terminationStatus)
            chained?(ended)
        }
        DeathRecords.spawning(key)
        try process.run()
        let pid = process.processIdentifier
        SpawnedProcessRegistry.register(pid, ownGroup: true)
        var bsd = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        let rc = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, size)
        let info = rc == size ? bsd : nil
        DeathRecords.spawned(key, pid: pid, ppid: info.map { pid_t($0.pbi_ppid) }, pgid: info.map { pid_t($0.pbi_pgid) })
    }

    /// How `process` ended, if it has: the termination reason and status, and
    /// how long after spawn. Safe to call at any time; never reads
    /// `terminationReason` from a running `Process`.
    func deathReport(for process: Process) -> String {
        DeathRecords.report(ObjectIdentifier(process))
    }

    /// `SIGKILL`s and reaps every process this fixture has run, in the order
    /// they were registered. Idempotent, and safe to call on a process that
    /// never started or has already exited.
    func killAndReapAll() {
        let tracked = lock.withLock {
            defer { processes.removeAll() }
            return processes
        }
        for process in tracked {
            Self.killAndReap(process)
        }
        SignalCanary.recordFindings()
    }

    /// Sends `SIGKILL` to `process` if it's still running, then blocks until
    /// it has actually exited. `Process.waitUntilExit()` here is the
    /// documented exception to "assert only once signalled"
    /// (`issues/0427.md:165`'s "not counted as violations" list includes
    /// `Process.waitUntilExit()` on children that exit by themselves) —
    /// forcing the exit with `SIGKILL` first makes this that same case, not
    /// a wait on real time passing.
    static func killAndReap(_ process: Process?) {
        guard let process, process.isRunning else { return }
        ProcessSignal.send(SIGKILL, to: process)
        process.waitUntilExit()
    }
}

/// Lock-protected spawn and death records for `ChildProcessFixture` children,
/// keyed by the `Process` object's identity.
nonisolated enum DeathRecords {
    private struct Entry {
        var spawnedAt: ContinuousClock.Instant
        var pid: pid_t = 0
        var ppid: pid_t?
        var pgid: pid_t?
        var died: (at: ContinuousClock.Instant, reason: Process.TerminationReason, status: Int32)?
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var entries: [ObjectIdentifier: Entry] = [:]

    static func spawning(_ key: ObjectIdentifier) {
        lock.withLock { entries[key] = Entry(spawnedAt: .now) }
    }

    static func spawned(_ key: ObjectIdentifier, pid: pid_t, ppid: pid_t?, pgid: pid_t?) {
        lock.withLock {
            entries[key]?.pid = pid
            entries[key]?.ppid = ppid
            entries[key]?.pgid = pgid
        }
    }

    static func record(_ key: ObjectIdentifier, reason: Process.TerminationReason, status: Int32) {
        lock.withLock { entries[key]?.died = (.now, reason, status) }
    }

    static func report(_ key: ObjectIdentifier) -> String {
        guard let entry = lock.withLock({ entries[key] }) else { return "no spawn record" }
        let family = "spawn ppid=\(entry.ppid.map(String.init) ?? "?") (self \(getpid())) pgid=\(entry.pgid.map(String.init) ?? "?") (runner \(getpgrp()))"
        guard let died = entry.died else { return "still running; \(family)" }
        let ms = (died.at - entry.spawnedAt).components.attoseconds / 1_000_000_000_000_000
            + (died.at - entry.spawnedAt).components.seconds * 1000
        let how: String
        switch died.reason {
        case .uncaughtSignal:
            how = "uncaughtSignal \(died.status) (\(String(cString: strsignal(died.status))))"
        case .exit:
            how = "exit status \(died.status)"
        @unknown default:
            how = "unknown reason \(died.status)"
        }
        return "died after \(ms) ms: \(how); \(family)"
    }
}
