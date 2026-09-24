// PendingTeardownReapRegistry.swift

import Darwin
import Foundation
import OSLog

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "PendingTeardownReapRegistry")

/// Process-wide registry of subprocess reaps that `LMStudioDashboardPaneContent`
/// (#0354) and `ProcessGitStatusScanner` (#0422) schedule onto a detached
/// task right after sending `SIGTERM` — a bounded wait for the child to
/// actually exit, escalating to `SIGKILL` if it doesn't.
///
/// `WindowRuntime.tearDownAllPaneContentSynchronouslyForQuit()`'s
/// `DeferredTeardownWaiting` walk only reaches a reap whose owning pane is
/// still in `AppStateStore.windows` at quit time. A pane, tab, session, or
/// window closed moments before quit already tore its content down and left
/// the model tree, so its reap was reachable only by the detached task
/// racing process exit against the app quitting (#0425) — including
/// "closing the last window," which schedules `NSApp.terminate(nil)` on the
/// next run-loop turn (`AppStateStore.terminateIfLastContentWindowGone`)
/// after the window (and every pane in it) is already gone from `windows`.
///
/// This registry is independent of the model tree: a conformer registers
/// here the moment it schedules the detached reap task, and deregisters
/// when that task completes, regardless of what later happens to the
/// pane/window that owned it. `drainSynchronously()` can therefore finish
/// every outstanding reap unconditionally, whether or not anything in
/// `AppStateStore` still references it.
///
/// `nonisolated` and lock-protected rather than an actor: `drainSynchronously()`
/// runs from `BattyAppDelegate.applicationWillTerminate` — synchronous,
/// `@MainActor` by the package default, and the last call before the
/// process exits. It must actually block that thread until every reap is
/// done, not suspend it at an `await` and hand control back to the run
/// loop, which is what calling into an actor's isolated method would do.
/// Mirrors `ProcessGitStatusScanner`'s own `NSLock` + `@unchecked Sendable`
/// shape (#0422), generalized from one scanner instance to every kind that
/// schedules a deferred reap.
public nonisolated final class PendingTeardownReapRegistry: @unchecked Sendable {
    /// The instance every production conformer registers into by default.
    /// A test injects a fresh instance instead — mirroring
    /// `LMStudioDashboardPaneContent`'s other injectable dependencies
    /// (`cliExecutableURLProvider`, `fetchModels`, ...) — so concurrent test
    /// suites can't observe each other's pending reaps through this shared
    /// global.
    public static let shared = PendingTeardownReapRegistry()

    private struct Entry {
        let process: Process
        let label: String
        let bound: TimeInterval
    }

    private let lock = NSLock()
    private var entries: [UUID: Entry] = [:]

    public init() {}

    /// Records `process` as a pending reap. `SIGTERM` is already sent by
    /// the caller before this is reached — this only tracks the bounded
    /// wait/`SIGKILL` escalation that still needs to happen. The caller's
    /// own detached task runs on the cooperative thread pool and can start
    /// right away; the risk this guards against is that task not
    /// *completing* before the whole process exits, not that it never
    /// starts — `drainSynchronously()` can finish that wait itself either
    /// way.
    @discardableResult
    func register(process: Process, label: String, bound: TimeInterval) -> UUID {
        let token = UUID()
        lock.lock()
        entries[token] = Entry(process: process, label: label, bound: bound)
        lock.unlock()
        return token
    }

    /// Removes a pending reap once the caller's own detached task has
    /// finished it. Idempotent: deregistering a token that isn't present
    /// (already drained, or never registered) is a no-op.
    func deregister(_ token: UUID) {
        lock.lock()
        entries.removeValue(forKey: token)
        lock.unlock()
    }

    /// Drains every still-pending reap synchronously on the calling
    /// thread. `applicationWillTerminate` is the only production caller,
    /// after the per-window `DeferredTeardownWaiting` walk. That walk never
    /// deregisters anything here, and the detached tasks it triggers (via
    /// each conformer's own `tearDown()`) are typically still running at
    /// that point — so this routinely finds entries the walk already
    /// handled, alongside any it couldn't reach at all (content already
    /// outside the model, #0425's actual gap). Both are fine to re-reap:
    /// `reapAfterTerminate` on an already-exited process observes that and
    /// returns immediately. Racing a process still alive is also fine, just
    /// not free — two callers can each independently reach the `SIGKILL`
    /// branch for the same process, which (if it also survives `SIGKILL`,
    /// the escalation's own worst case) doubles the time spent polling it
    /// versus a single caller doing so.
    ///
    /// Bounded by the sum of each entry's own `bound + min(bound, 0.5)`,
    /// run sequentially — not a shared deadline across entries, the same
    /// non-goal `DeferredTeardownWaiting` documents for its own
    /// per-conformer wait.
    public func drainSynchronously() {
        lock.lock()
        let pending = Array(entries.values)
        entries.removeAll()
        lock.unlock()
        guard !pending.isEmpty else { return }
        logger.notice("drainSynchronously: \(pending.count, privacy: .public) pending reap(s)")
        for entry in pending {
            Self.reapAfterTerminate(entry.process, bound: entry.bound, label: entry.label)
        }
    }

    /// Same shape as `LMStudioDashboardPaneContent.reapAfterTerminate`/
    /// `ProcessGitStatusScanner.reapAfterTerminate` (#0354, #0422): poll
    /// `Process.isRunning` for at most `bound`, then `SIGKILL` and re-poll
    /// if the child is still alive, so completion means the child has
    /// actually exited, not just been signaled.
    nonisolated private static func reapAfterTerminate(_ process: Process, bound: TimeInterval, label: String) {
        let deadline = Date().addingTimeInterval(bound)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        guard process.isRunning else {
            logger.info("drainSynchronously: \(label, privacy: .public) exited within bound")
            return
        }
        logger.error("drainSynchronously: \(label, privacy: .public) did not exit within \(bound, privacy: .public)s bound; sending SIGKILL")
        kill(process.processIdentifier, SIGKILL)
        let killDeadline = Date().addingTimeInterval(min(bound, 0.5))
        while process.isRunning, Date() < killDeadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            logger.error("drainSynchronously: \(label, privacy: .public) still running after SIGKILL")
        } else {
            logger.info("drainSynchronously: \(label, privacy: .public) exited after SIGKILL")
        }
    }

    // MARK: - Test support

    /// Number of reaps currently tracked — `internal`, not `private`, so
    /// `PendingTeardownReapRegistryTests` can assert registration and
    /// deregistration directly. Never called from production code.
    var pendingCountForTesting: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }
}
