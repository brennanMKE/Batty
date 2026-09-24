// ChildProcessFixture.swift

import Darwin
import Foundation

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
@MainActor
final class ChildProcessFixture {
    private var processes: [Process] = []

    /// Tracks `process` for cleanup, then runs it.
    func run(_ process: Process) throws {
        processes.append(process)
        try process.run()
    }

    /// `SIGKILL`s and reaps every process this fixture has run, in the order
    /// they were registered. Idempotent, and safe to call on a process that
    /// never started or has already exited.
    func killAndReapAll() {
        for process in processes {
            Self.killAndReap(process)
        }
        processes.removeAll()
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
        kill(process.processIdentifier, SIGKILL)
        process.waitUntilExit()
    }
}
