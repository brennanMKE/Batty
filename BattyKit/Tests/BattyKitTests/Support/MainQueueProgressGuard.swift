// MainQueueProgressGuard.swift

import Foundation

nonisolated struct ProgressGuardScheduler: Sendable {
    let after: @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void
    let onMain: @Sendable (@escaping @Sendable () -> Void) -> Void

    static let live = ProgressGuardScheduler(
        after: { interval, work in
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + interval, execute: work)
        },
        onMain: { work in DispatchQueue.main.async(execute: work) }
    )
}

/// Records timers and main-queue blocks instead of scheduling them, so the
/// guard's own tests step through intervals without real time passing.
nonisolated final class ManualProgressGuardScheduler: @unchecked Sendable {
    private let lock = NSLock()
    private var timers: [@Sendable () -> Void] = []
    private var mainBlocks: [@Sendable () -> Void] = []

    var scheduler: ProgressGuardScheduler {
        ProgressGuardScheduler(
            after: { [self] _, work in lock.withLock { timers.append(work) } },
            onMain: { [self] work in lock.withLock { mainBlocks.append(work) } }
        )
    }

    var pendingTimerCount: Int { lock.withLock { timers.count } }
    var pendingMainCount: Int { lock.withLock { mainBlocks.count } }

    func fireTimers() {
        let due = lock.withLock { () -> [@Sendable () -> Void] in
            defer { timers.removeAll() }
            return timers
        }
        due.forEach { $0() }
    }

    func runMainBlocks() {
        let due = lock.withLock { () -> [@Sendable () -> Void] in
            defer { mainBlocks.removeAll() }
            return mainBlocks
        }
        due.forEach { $0() }
    }
}

nonisolated struct ProgressGuardExpiry: Sendable {
    let progress: Int
    let backloggedIntervals: Int
}

/// Hang guard for waits whose steps run on the main queue. A one-shot
/// wall-clock guard cannot tell "the main queue is a minute deep" from
/// "the awaited event was lost", so this one expires only after two
/// consecutive `bound` intervals in which `progress()` did not advance
/// **and** a sentinel block posted to `DispatchQueue.main` at the start of
/// the interval already ran, i.e. everything queued before it drained.
/// An interval whose sentinel has not run yet is counted as backlogged and
/// the guard re-arms. Two strikes, not one, cover a step stamped just
/// before its successor hop was enqueued. See `docs/async-test-seams.md` §4.
nonisolated final class MainQueueProgressGuard: @unchecked Sendable {
    private let lock = NSLock()
    private let bound: TimeInterval
    private let scheduler: ProgressGuardScheduler
    private let progress: @Sendable () -> Int
    private let onExpire: @Sendable (ProgressGuardExpiry) -> Void

    private var cancelled = false
    private var expired = false
    private var lastProgress = 0
    private var strikes = 0
    private var backloggedIntervals = 0
    private var sentinelGeneration = 0
    private var sentinelRan = false

    init(
        bound: TimeInterval = TestBounds.hangGuard,
        scheduler: ProgressGuardScheduler = .live,
        progress: @escaping @Sendable () -> Int,
        onExpire: @escaping @Sendable (ProgressGuardExpiry) -> Void
    ) {
        self.bound = bound
        self.scheduler = scheduler
        self.progress = progress
        self.onExpire = onExpire
    }

    func arm() {
        let current = progress()
        lock.withLock { lastProgress = current }
        postSentinel()
        scheduleTimer()
    }

    func cancel() {
        lock.withLock { cancelled = true }
    }

    private func postSentinel() {
        let generation = lock.withLock { () -> Int in
            sentinelGeneration += 1
            sentinelRan = false
            return sentinelGeneration
        }
        scheduler.onMain { [self] in
            lock.withLock {
                if sentinelGeneration == generation { sentinelRan = true }
            }
        }
    }

    private func scheduleTimer() {
        scheduler.after(bound) { [self] in tick() }
    }

    private enum Decision {
        case stop
        case rearm(newSentinel: Bool)
        case expire(ProgressGuardExpiry)
    }

    private func tick() {
        let current = progress()
        let decision = lock.withLock { () -> Decision in
            if cancelled || expired { return .stop }
            if current != lastProgress {
                lastProgress = current
                strikes = 0
                return .rearm(newSentinel: true)
            }
            if !sentinelRan {
                backloggedIntervals += 1
                return .rearm(newSentinel: false)
            }
            strikes += 1
            if strikes >= 2 {
                expired = true
                return .expire(ProgressGuardExpiry(progress: current, backloggedIntervals: backloggedIntervals))
            }
            return .rearm(newSentinel: true)
        }
        switch decision {
        case .stop:
            return
        case .rearm(let newSentinel):
            if newSentinel { postSentinel() }
            scheduleTimer()
        case .expire(let expiry):
            onExpire(expiry)
        }
    }
}
