// TestClockTests.swift

import Foundation
import Testing
@testable import BattyKit

/// Direct coverage of `TestClock`'s own advance/registration/cancellation
/// contract — the piece every #0427 child routes its periodic/deferred
/// work through, so a mistake here can't hide behind any one conformer's
/// own bookkeeping. Deliberately exercises a lower-priority sleeper, real
/// async work between ticks, and several concurrent sleepers, since none
/// of those may assume anything about relative scheduling order.
nonisolated struct TestClockTests {
    /// A safety net for a test whose success path awaits a `Task` that a
    /// regression could leave permanently stuck on `clock`. After `bound`,
    /// if not already cancelled, this releases every currently-parked
    /// sleeper (unblocking whatever the test is stuck awaiting, so it can
    /// still finish instead of hanging the run) and records the real
    /// failure via `Issue.record` — the original assertions may now pass
    /// vacuously once the parked sleepers are force-released, so this is
    /// the actual signal a regression fails on. Call `cancel()` once the
    /// awaited work completes normally.
    private func startStuckSleeperGuard(
        for clock: TestClock,
        bound: TimeInterval = TestBounds.hangGuard,
        sourceLocation: SourceLocation = #_sourceLocation
    ) -> Task<Void, Never> {
        Task {
            try? await Task.sleep(for: .seconds(bound))
            guard !Task.isCancelled else { return }
            let parked = await clock.advance(by: .seconds(10_000))
            if parked > 0 {
                Issue.record(
                    "timed out after \(bound)s with \(parked) sleeper(s) still parked — a regression left them stuck instead of resuming",
                    sourceLocation: sourceLocation
                )
            }
        }
    }

    /// `waitForSleepers` returning `false` means its hang-guard bound
    /// elapsed instead of a real registration event. A bare
    /// `#expect(await clock.waitForSleepers(...))` records that but lets
    /// the test carry on as if the sleeper existed — and a later `await
    /// task.value` can then block for real, on a sleeper that will now
    /// never be released (nothing else in the test still calls `advance`
    /// expecting it). This records the actual failure and cancels every
    /// task passed in — `TestClock.sleep(for:)`'s cancellation handler
    /// releases a sleeper whether or not it had registered yet — so a
    /// caller can safely `return` right after.
    @discardableResult
    private func requireSleepers(
        _ count: Int,
        on clock: TestClock,
        cancelling tasks: [any CancellableWork],
        sourceLocation: SourceLocation = #_sourceLocation
    ) async -> Bool {
        let ready = await clock.waitForSleepers(count)
        if !ready {
            Issue.record("waitForSleepers(\(count)) never reached its threshold", sourceLocation: sourceLocation)
            for task in tasks { task.cancel() }
        }
        return ready
    }

    @Test func sleepRegistersAPendingSleeperUntilItsDeadlineIsReached() async {
        let clock = TestClock()
        #expect(clock.pendingCount == 0)

        let task = Task { await clock.sleep(for: .seconds(1)) }
        guard await requireSleepers(1, on: clock, cancelling: [task]) else { return }
        #expect(clock.pendingCount == 1)

        await clock.advance(by: .seconds(1))
        #expect(clock.pendingCount == 0)
        await task.value
    }

    @Test func advanceDoesNotFireASleeperBeforeItsDeadline() async {
        let clock = TestClock()
        let task = Task {
            await clock.sleep(for: .seconds(2))
        }
        guard await requireSleepers(1, on: clock, cancelling: [task]) else { return }

        await clock.advance(by: .seconds(1))
        #expect(clock.pendingCount == 1, "a sleeper due at 2s must not fire after only 1s of advance")

        await clock.advance(by: .seconds(1))
        await task.value // completing is the "fired" signal
    }

    /// The pattern `ProcessStatusPaneContent`'s sampler proving use relies
    /// on: `advance(by:)` fires the due sleeper, then `waitForSleepers(1)`
    /// — a real registration event, not a guess — confirms the woken
    /// (fully synchronous, in this test) remainder ran and re-armed before
    /// the next assertion.
    @Test func advanceThenWaitForSleepersObservesTheSynchronousWorkASleeperRunsAfterWaking() async {
        let clock = TestClock()
        let sampleCount = LockedCounter()
        let task = Task {
            while true {
                await clock.sleep(for: .seconds(1))
                if sampleCount.increment() >= 3 { return }
            }
        }
        guard await requireSleepers(1, on: clock, cancelling: [task]) else { return }

        await clock.advance(by: .seconds(1))
        guard await requireSleepers(1, on: clock, cancelling: [task]) else { return }
        #expect(sampleCount.current == 1)

        await clock.advance(by: .seconds(1))
        guard await requireSleepers(1, on: clock, cancelling: [task]) else { return }
        #expect(sampleCount.current == 2)

        await clock.advance(by: .seconds(1))
        // Third iteration returns instead of re-registering — nothing to
        // wait for; `task.value` is the completion signal.
        await task.value
        #expect(sampleCount.current == 3)
    }

    /// A sleeper on a *lower*-priority task. A hop-based "let it register"
    /// (or "let it re-arm") technique is not reliable across priorities;
    /// `waitForSleepers` is a real event with no dependency on relative
    /// scheduling at all.
    @Test func waitForSleepersWorksForALowerPrioritySleeper() async {
        let clock = TestClock()
        let task = Task(priority: .background) {
            await clock.sleep(for: .seconds(1))
        }
        guard await requireSleepers(1, on: clock, cancelling: [task]) else { return }
        #expect(clock.pendingCount == 1)

        await clock.advance(by: .seconds(1))
        await task.value // completing is the "fired" signal
    }

    /// Real async work *between* one `sleep(for:)` call and the next (the
    /// actual shape of LM Studio's `startModelsPollTask`/`startPsPollTask`,
    /// which `await pollModelsOnce()`/`pollPsOnce()` before looping back to
    /// sleep). A single multi-interval `advance(by:)` cannot "catch" the
    /// second tick here — see
    /// `advanceOnlyFiresAlreadyRegisteredSleepersAndReportsHowManyFired`
    /// below for that behavior made explicit — so the correct pattern is
    /// one `advance(by:)` + `waitForSleepers(1)` per tick, which this test
    /// shows working regardless of how long the interleaved async work
    /// takes.
    @Test func waitForSleepersWorksAcrossAsyncWorkBetweenTicks() async {
        let clock = TestClock()
        let tickCount = LockedCounter()
        let task = Task {
            while true {
                await clock.sleep(for: .seconds(1))
                // Simulate a poll awaiting real async work before its next
                // sleep — real suspension points off the current task,
                // not a single synchronous remainder, and no reliance on
                // any specific amount of time passing.
                await Task.yield()
                await Task.detached {}.value
                await Task.yield()
                if tickCount.increment() >= 3 { return }
            }
        }
        guard await requireSleepers(1, on: clock, cancelling: [task]) else { return }

        await clock.advance(by: .seconds(1))
        guard await requireSleepers(1, on: clock, cancelling: [task]) else { return } // tick 1 finished its async work and re-armed
        #expect(tickCount.current == 1)

        await clock.advance(by: .seconds(1))
        guard await requireSleepers(1, on: clock, cancelling: [task]) else { return } // tick 2 finished its async work and re-armed
        #expect(tickCount.current == 2)

        await clock.advance(by: .seconds(1)) // fires the 3rd and final tick
        await task.value // the task returns instead of re-registering — no waitForSleepers to wait on
        #expect(tickCount.current == 3)
    }

    /// A single `advance(by:)` only fires sleepers already registered the
    /// instant it's called — it does not wait for a resumed remainder
    /// (which may contain unbounded async work) to re-register a new one.
    /// The returned count makes that explicit instead of silent: a caller
    /// that assumed 5 ticks from one call gets `1` back, not a quiet
    /// under-fire.
    @Test func advanceOnlyFiresAlreadyRegisteredSleepersAndReportsHowManyFired() async {
        let clock = TestClock()
        let task = Task { () -> Int in
            var fireCount = 0
            while true {
                await clock.sleep(for: .milliseconds(100))
                // Real async work between ticks, like LM Studio's poll
                // loops — see this type's own doc comment.
                await Task.yield()
                fireCount += 1
                if fireCount >= 5 { return fireCount }
            }
        }
        guard await requireSleepers(1, on: clock, cancelling: [task]) else { return }

        let fired = await clock.advance(by: .milliseconds(500))

        #expect(fired == 1, "a multi-interval advance must not silently claim more ticks fired than were actually registered")

        // Drain the remaining 4 ticks one at a time so the task can finish
        // cleanly. A fixed count, not a `while` bound on the task's own
        // (now task-local) counter: after the task's final tick it returns
        // without re-registering, so a `waitForSleepers` call after that
        // point would only resolve via its hang-guard bound — a fixed
        // count avoids ever making that call.
        for _ in 0..<4 {
            guard await requireSleepers(1, on: clock, cancelling: [task]) else { return }
            await clock.advance(by: .milliseconds(100))
        }
        let fireCount = await task.value
        #expect(fireCount == 5)
    }

    /// A sleeper due later than the advance target is left pending — the
    /// "nothing is scheduled yet" half of the contract.
    @Test func advanceLeavesALaterSleeperPending() async {
        let clock = TestClock()
        let task = Task { await clock.sleep(for: .seconds(10)) }
        guard await requireSleepers(1, on: clock, cancelling: [task]) else { return }

        await clock.advance(by: .seconds(1))

        #expect(clock.pendingCount == 1)
        await clock.advance(by: .seconds(9))
        #expect(clock.pendingCount == 0)
        await task.value
    }

    /// `now` reflects each `advance(by:)` call's own target as soon as it
    /// returns, and accumulates correctly across separate tick-by-tick
    /// calls — code that reads `clock.now` after each tick (a future
    /// child's stale-window comparison) sees the running total, not a
    /// value reset or skewed by the previous call.
    @Test func nowAccumulatesAcrossSeparateSingleTickAdvanceCalls() async {
        let clock = TestClock()
        let task = Task { () -> [Date] in
            var observedNows: [Date] = []
            while true {
                await clock.sleep(for: .seconds(1))
                observedNows.append(clock.now)
                if observedNows.count >= 3 { return observedNows }
            }
        }
        guard await requireSleepers(1, on: clock, cancelling: [task]) else { return }

        await clock.advance(by: .seconds(1))
        guard await requireSleepers(1, on: clock, cancelling: [task]) else { return } // tick 1 done, re-armed
        await clock.advance(by: .seconds(1))
        guard await requireSleepers(1, on: clock, cancelling: [task]) else { return } // tick 2 done, re-armed
        await clock.advance(by: .seconds(1)) // fires tick 3 (final)
        let observedNows = await task.value

        let start = Date(timeIntervalSince1970: 0)
        #expect(observedNows == [
            start.addingTimeInterval(1),
            start.addingTimeInterval(2),
            start.addingTimeInterval(3),
        ])
    }

    @Test func pendingCountReflectsMultipleConcurrentSleepers() async {
        let clock = TestClock()
        let taskA = Task { await clock.sleep(for: .seconds(1)) }
        let taskB = Task { await clock.sleep(for: .seconds(2)) }
        guard await requireSleepers(2, on: clock, cancelling: [taskA, taskB]) else { return }

        #expect(clock.pendingCount == 2)

        await clock.advance(by: .seconds(2))

        #expect(clock.pendingCount == 0)
        await taskA.value
        await taskB.value
    }

    // MARK: - Cancellation

    /// `TestClock.sleep(for:)` must wake promptly on cancellation, the same
    /// way `SystemClock`'s real `Task.sleep` does — not sit registered
    /// until some later `advance(by:)` happens to reach its deadline.
    @Test func cancellingTheCallerRemovesItsSleeperImmediately() async {
        let clock = TestClock()
        let task = Task {
            await clock.sleep(for: .seconds(100))
        }
        guard await requireSleepers(1, on: clock, cancelling: [task]) else { return }
        #expect(clock.pendingCount == 1)

        task.cancel()

        #expect(clock.pendingCount == 0, "cancellation must remove the pending sleeper synchronously, not eventually")
        await task.value
    }

    @Test func cancellingOneOfSeveralSleepersLeavesTheOthersPending() async {
        let clock = TestClock()
        let cancelled = Task { await clock.sleep(for: .seconds(100)) }
        let survivor = Task { await clock.sleep(for: .seconds(1)) }
        guard await requireSleepers(2, on: clock, cancelling: [cancelled, survivor]) else { return }

        cancelled.cancel()

        #expect(clock.pendingCount == 1)
        await cancelled.value

        await clock.advance(by: .seconds(1))
        #expect(clock.pendingCount == 0)
        await survivor.value
    }

    /// A task already cancelled before it ever calls `sleep(for:)` must
    /// resume immediately without parking — matching `Task.sleep`, which
    /// throws right away for an already-cancelled task rather than sleeping
    /// first. `withUnsafeCurrentTask { $0?.cancel() }` cancels the task from
    /// inside its own body, before its first `await` — that guarantees
    /// `Task.isCancelled` already reads `true` by the time `sleep(for:)`
    /// checks it, since cancelling from inside the task can never race its
    /// own start.
    @Test func aTaskCancelledBeforeItSleepsResumesImmediatelyWithoutParking() async {
        let clock = TestClock()
        let guardTask = startStuckSleeperGuard(for: clock)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await clock.sleep(for: .seconds(100))
            return clock.pendingCount
        }

        let pendingCountObservedInsideTheTask = await task.value
        guardTask.cancel()

        #expect(pendingCountObservedInsideTheTask == 0, "an already-cancelled task must never register a sleeper")
        #expect(clock.pendingCount == 0)
    }

    /// Cancellation racing registration: the sleeper and its canceller are
    /// two independently-scheduled unstructured tasks, so the scheduler
    /// alone decides whether `cancel()` lands before, during, or after
    /// `register(id:duration:continuation:)` takes the lock. Repeated many
    /// times to make the narrow "during" window actually likely to be hit
    /// at least once. Every pair is created (and raced) before any of them
    /// is awaited — a regression can strand more than one sleeper across
    /// 2000 iterations, and the guard's single `advance(by:)` only releases
    /// whatever is *already* parked when it fires, so every pair's outcome
    /// must already be settled by then, not still in flight one at a time.
    @Test func cancellationRacingRegistrationNeverLeavesASleeperParkedForever() async {
        let clock = TestClock()
        let guardTask = startStuckSleeperGuard(for: clock)

        var sleepers: [Task<Void, Never>] = []
        sleepers.reserveCapacity(2000)
        for _ in 0..<2000 {
            let sleeper = Task { await clock.sleep(for: .seconds(100)) }
            let canceller = Task { sleeper.cancel() }
            await canceller.value
            sleepers.append(sleeper)
        }
        for sleeper in sleepers {
            await sleeper.value
        }
        guardTask.cancel()

        #expect(clock.pendingCount == 0, "every iteration's sleeper must have resumed one way or another, never left parked")
    }
}

/// A plain counter safe to increment from an unstructured task and read
/// from the awaiting test concurrently, at intermediate checkpoints before
/// the task completes — Swift's strict concurrency correctly refuses to let
/// an escaping, non-actor-isolated task closure capture and mutate a plain
/// `var` for exactly this reason.
private nonisolated final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    @discardableResult
    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }

    var current: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// Type-erases `Task<Success, Failure>.cancel()` so a single array can hold
/// tasks with different `Success` types (`Void`, `Int`, `[Date]`, ...).
private protocol CancellableWork {
    nonisolated func cancel()
}

extension Task: CancellableWork {}
