// MainQueueProgressGuardTests.swift

import Foundation
import Testing

private nonisolated final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var current: Int { lock.withLock { value } }
    func bump() { lock.withLock { value += 1 } }
}

private nonisolated final class ExpiryLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [ProgressGuardExpiry] = []
    var all: [ProgressGuardExpiry] { lock.withLock { entries } }
    func append(_ expiry: ProgressGuardExpiry) { lock.withLock { entries.append(expiry) } }
}

private nonisolated func makeGuard(
    _ manual: ManualProgressGuardScheduler,
    progress: Counter,
    log: ExpiryLog
) -> MainQueueProgressGuard {
    MainQueueProgressGuard(
        bound: 60,
        scheduler: manual.scheduler,
        progress: { progress.current },
        onExpire: { log.append($0) }
    )
}

nonisolated struct MainQueueProgressGuardTests {
    /// One interval: the main queue drains, then the timer fires.
    private func quietInterval(_ manual: ManualProgressGuardScheduler) {
        manual.runMainBlocks()
        manual.fireTimers()
    }

    @Test func expiresAfterTwoQuietIntervalsWithADrainedMainQueue() {
        let manual = ManualProgressGuardScheduler()
        let log = ExpiryLog()
        let progressGuard = makeGuard(manual, progress: Counter(), log: log)
        progressGuard.arm()

        quietInterval(manual)
        #expect(log.all.isEmpty)
        quietInterval(manual)
        #expect(log.all.count == 1)
        #expect(manual.pendingTimerCount == 0)
    }

    @Test func reArmsWhileTheMainQueueIsBacklogged() {
        let manual = ManualProgressGuardScheduler()
        let log = ExpiryLog()
        let progressGuard = makeGuard(manual, progress: Counter(), log: log)
        progressGuard.arm()

        for _ in 0..<10 {
            manual.fireTimers()
        }
        #expect(log.all.isEmpty)
        #expect(manual.pendingTimerCount == 1)

        quietInterval(manual)
        #expect(log.all.isEmpty)
        quietInterval(manual)
        #expect(log.all.map(\.backloggedIntervals) == [10])
    }

    @Test func progressResetsTheStrikeCount() {
        let manual = ManualProgressGuardScheduler()
        let log = ExpiryLog()
        let counter = Counter()
        let progressGuard = makeGuard(manual, progress: counter, log: log)
        progressGuard.arm()

        quietInterval(manual)
        counter.bump()
        quietInterval(manual)
        quietInterval(manual)
        #expect(log.all.isEmpty)
        quietInterval(manual)
        #expect(log.all.map(\.progress) == [1])
    }

    @Test func cancelStopsFurtherTimersAndExpiry() {
        let manual = ManualProgressGuardScheduler()
        let log = ExpiryLog()
        let progressGuard = makeGuard(manual, progress: Counter(), log: log)
        progressGuard.arm()

        quietInterval(manual)
        progressGuard.cancel()
        quietInterval(manual)
        quietInterval(manual)
        #expect(log.all.isEmpty)
        #expect(manual.pendingTimerCount == 0)
    }

    @Test func expiresOnlyOnce() {
        let manual = ManualProgressGuardScheduler()
        let log = ExpiryLog()
        let progressGuard = makeGuard(manual, progress: Counter(), log: log)
        progressGuard.arm()

        for _ in 0..<6 {
            quietInterval(manual)
        }
        #expect(log.all.count == 1)
    }
}
