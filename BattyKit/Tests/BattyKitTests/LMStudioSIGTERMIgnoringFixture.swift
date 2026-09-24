// LMStudioSIGTERMIgnoringFixture.swift

import Foundation

/// Shared by `LMStudioDashboardPaneContentTests` and
/// `LMStudioDashboardWiringTests` (#0424): both suites need a `/bin/sh`
/// child that ignores `SIGTERM` (`trap '' TERM`) to exercise the `SIGKILL`
/// escalation in `LMStudioDashboardPaneContent.reapAfterTerminate`. Kept in
/// one place so the two suites' fixtures can't drift back into the
/// fixed-sleep race #0424 fixed in one file but not the other.
///
/// A fixed wall-clock sleep after spawn cannot prove the trap is installed:
/// under host load, `sh` may not have parsed `trap '' TERM` yet by the time
/// the sleep elapses, so a `SIGTERM` sent before the trap installs kills the
/// child on the default disposition — the `SIGKILL` branch never runs, and
/// the test passes whether or not escalation actually works (#0422 hit this
/// for real: 20/20 kills on `SIGTERM` with no delay). `makeProcess` instead
/// has the fixture write a ready file right after the `trap` builtin
/// returns; `waitForReadyFile` polls for it. A stdout `Pipe` won't do this
/// safely for the LM Studio content: `spawnModelStream`/`spawnRuntimeStream`
/// replace the process's own `standardOutput`/`standardError` with pipes and
/// readability handlers they own, so a test-owned pipe on the same process
/// would race the content's own handler for the same bytes — a separate
/// file avoids that entirely.
///
/// `exec` (not a bare `sleep 60`) replaces the shell's own process image
/// with `sleep` instead of forking it; `SIG_IGN` survives `exec`, so the
/// ignored disposition `trap` set carries over to `sleep` directly and
/// exactly one process exists at any point — a `SIGKILL` on that single pid
/// leaves nothing behind. Without `exec`, `sleep` runs as `sh`'s forked
/// child, so a signal that only reaches `sh`'s pid (the pid `Process`
/// reports and the one `terminate()`/`SIGKILL` target) orphans the `sleep`
/// grandchild for up to its own 60s lifetime.
enum LMStudioSIGTERMIgnoringFixture {
    /// A process that installs a `SIGTERM` trap, signals readiness by
    /// writing to `readyFileURL`, then execs into `sleep 60`. Callers must
    /// wait on `waitForReadyFile(_:)` before treating the process's
    /// disposition as installed.
    static func makeProcess(readyFileURL: URL) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "trap '' TERM; echo ready > '\(readyFileURL.path)'; exec sleep 60"]
        return process
    }

    /// Polls the filesystem for the ready file `makeProcess`'s fixture
    /// writes right after installing its `SIGTERM` trap — the deterministic
    /// replacement for a fixed sleep before the test sends `SIGTERM`.
    static func waitForReadyFile(_ url: URL, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !FileManager.default.fileExists(atPath: url.path), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// A fresh temp directory for one test's ready file(s), plus a matching
    /// cleanup closure the caller runs in a `defer`.
    static func makeReadyDirectory(callerTag: String) throws -> (directory: URL, cleanup: () -> Void) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("batty-0424-\(callerTag)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (directory, { try? FileManager.default.removeItem(at: directory) })
    }
}
