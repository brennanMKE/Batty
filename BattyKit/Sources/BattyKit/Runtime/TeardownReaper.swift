// TeardownReaper.swift

import Darwin
import Foundation
import OSLog

/// The bounded wait for a `SIGTERM`ed child to exit, escalating to
/// `SIGKILL` if it doesn't (#0354, #0425), shared by
/// `LMStudioDashboardPaneContent` and `PendingTeardownReapRegistry`.
///
/// The `SIGTERM` → `SIGKILL` grace period of `bound` runs on the injected
/// `SchedulingClock` (`docs/async-test-seams.md` §1), so a test advances
/// it explicitly instead of letting real time pass. Exit is still observed
/// by polling `Process.isRunning` every 20 ms — `Process` has no async
/// "did it exit" API — with `Task.sleep`, so a stuck reap never blocks a
/// cooperative-pool thread. The post-`SIGKILL` wait of `min(bound, 0.5)`
/// stays wall-clock: it only runs out when the child survives `SIGKILL`.
///
/// Returns only after the child is observed exited, not just signaled:
/// `Process.isRunning` flips only once Foundation's own exit-monitoring
/// source observes the exit, which the post-`SIGKILL` poll waits for.
nonisolated enum TeardownReaper {
    static func reap(
        _ process: Process,
        bound: TimeInterval,
        label: String,
        clock: SchedulingClock,
        logger: Logger,
        logPrefix: String
    ) async {
        guard process.isRunning else {
            logger.info("\(logPrefix, privacy: .public): \(label, privacy: .public) exited within bound")
            return
        }
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await clock.sleep(for: .milliseconds(Int(bound * 1000)))
            }
            group.addTask {
                while process.isRunning, !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(20))
                }
            }
            await group.next()
            group.cancelAll()
        }
        guard process.isRunning else {
            logger.info("\(logPrefix, privacy: .public): \(label, privacy: .public) exited within bound")
            return
        }
        logger.error("\(logPrefix, privacy: .public): \(label, privacy: .public) did not exit within \(bound, privacy: .public)s bound; sending SIGKILL")
        kill(process.processIdentifier, SIGKILL)
        let killDeadline = Date().addingTimeInterval(min(bound, 0.5))
        while process.isRunning, Date() < killDeadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        if process.isRunning {
            logger.error("\(logPrefix, privacy: .public): \(label, privacy: .public) still running after SIGKILL")
        } else {
            logger.info("\(logPrefix, privacy: .public): \(label, privacy: .public) exited after SIGKILL")
        }
    }

    /// For the synchronous quit and drain paths, which must block their
    /// thread until the reap is done rather than suspend at an `await`.
    static func reapBlocking(
        _ process: Process,
        bound: TimeInterval,
        label: String,
        clock: SchedulingClock,
        logger: Logger,
        logPrefix: String
    ) {
        let done = DispatchSemaphore(value: 0)
        // The reap runs on the cooperative pool while this thread waits on
        // a semaphore, so the grace period can be driven by an injected
        // clock even when the calling thread is the (blocked) main thread.
        Task.detached(priority: .utility) {
            await reap(process, bound: bound, label: label, clock: clock, logger: logger, logPrefix: logPrefix)
            done.signal()
        }
        done.wait()
    }
}
