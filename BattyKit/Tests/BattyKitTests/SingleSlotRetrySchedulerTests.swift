// SingleSlotRetrySchedulerTests.swift

import Testing
@testable import BattyKit

/// Covers the "at most one pending retry" invariant backing
/// `AppXPCCoordinator`'s self-healing backoff retry (#0361) — the regression
/// guard against several broker give-up events in a row (repeated
/// interruption/invalidation signals, a repeated repair failure) each
/// scheduling their own overlapping reconnect attempt instead of exactly
/// one. No `DispatchWorkItem`/`Timer` involved: a plain `Int` stands in for
/// a scheduled handle.
@MainActor
struct SingleSlotRetrySchedulerTests {

    @Test func replacingAPendingHandleCancelsThePreviousOne() {
        var cancelled: [Int] = []
        let scheduler = SingleSlotRetryScheduler<Int> { cancelled.append($0) }
        scheduler.replace(with: 1)
        scheduler.replace(with: 2)
        #expect(cancelled == [1])
        #expect(scheduler.hasPending)
    }

    @Test func repeatedReplaceEverLeavesAtMostOnePending() {
        // The exact #0361 property: N give-up events in a row schedule one
        // retry, not N — each new schedule cancels the last rather than
        // stacking alongside it.
        var cancelledCount = 0
        let scheduler = SingleSlotRetryScheduler<Int> { _ in cancelledCount += 1 }
        for attempt in 0..<5 {
            scheduler.replace(with: attempt)
        }
        #expect(cancelledCount == 4)
        #expect(scheduler.hasPending)
    }

    @Test func clearCancelsThePendingHandleAndResetsHasPending() {
        var cancelled: [Int] = []
        let scheduler = SingleSlotRetryScheduler<Int> { cancelled.append($0) }
        scheduler.replace(with: 1)
        scheduler.clear()
        #expect(cancelled == [1])
        #expect(!scheduler.hasPending)
    }

    @Test func clearWithNothingPendingCancelsNothing() {
        var cancelled: [Int] = []
        let scheduler = SingleSlotRetryScheduler<Int> { cancelled.append($0) }
        scheduler.clear()
        #expect(cancelled.isEmpty)
        #expect(!scheduler.hasPending)
    }

    @Test func freshSchedulerHasNothingPending() {
        let scheduler = SingleSlotRetryScheduler<Int> { _ in }
        #expect(!scheduler.hasPending)
    }

    @Test func clearAfterClearIsIdempotent() {
        var cancelledCount = 0
        let scheduler = SingleSlotRetryScheduler<Int> { _ in cancelledCount += 1 }
        scheduler.replace(with: 1)
        scheduler.clear()
        scheduler.clear()
        #expect(cancelledCount == 1)
    }

    // MARK: - #0367: the slot must clear when the handle fires, not just
    // when it is cancelled or replaced.

    @Test func markFiredClearsHasPendingWithoutCancelling() {
        var cancelled: [Int] = []
        let scheduler = SingleSlotRetryScheduler<Int> { cancelled.append($0) }
        scheduler.replace(with: 1)
        scheduler.markFired()
        #expect(cancelled.isEmpty)
        #expect(!scheduler.hasPending)
    }

    @Test func clearAfterMarkFiredDoesNotCancelTheAlreadyFiredHandle() {
        var cancelled: [Int] = []
        let scheduler = SingleSlotRetryScheduler<Int> { cancelled.append($0) }
        scheduler.replace(with: 1)
        scheduler.markFired()
        scheduler.clear()
        #expect(cancelled.isEmpty)
        #expect(!scheduler.hasPending)
    }

    @Test func replaceAfterMarkFiredDoesNotCancelTheAlreadyFiredHandle() {
        var cancelled: [Int] = []
        let scheduler = SingleSlotRetryScheduler<Int> { cancelled.append($0) }
        scheduler.replace(with: 1)
        scheduler.markFired()
        scheduler.replace(with: 2)
        #expect(cancelled.isEmpty)
        #expect(scheduler.hasPending)
    }

    @Test func replaceBeforeMarkFiredStillCancelsTheOldHandle() {
        // Pins the third #0367 requirement: markFired only forgives a
        // handle that actually ran — a handle superseded by replace(with:)
        // before it fires is still cancelled normally.
        var cancelled: [Int] = []
        let scheduler = SingleSlotRetryScheduler<Int> { cancelled.append($0) }
        scheduler.replace(with: 1)
        scheduler.replace(with: 2)
        scheduler.markFired()
        #expect(cancelled == [1])
        #expect(!scheduler.hasPending)
    }

    // MARK: - #0391: deinit must stay empty.

    @Test func deallocatingTheSchedulerWithAPendingHandleNeverCancelsIt() {
        var cancelledCount = 0
        do {
            let scheduler = SingleSlotRetryScheduler<Int> { _ in cancelledCount += 1 }
            scheduler.replace(with: 1)
        }
        #expect(cancelledCount == 0)
    }
}
