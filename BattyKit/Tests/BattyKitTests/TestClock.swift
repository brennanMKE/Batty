// TestClock.swift

import Foundation
@testable import BattyKit

/// Manually driven `SchedulingClock` for tests. Time never passes on its
/// own — a test calls `advance(by:)` to release the sleepers already
/// registered and due by that point, and `waitForSleepers(_:)` to await a
/// real "a sleeper just registered" signal.
///
/// Lock-guarded and `nonisolated`/`Sendable` rather than actor-isolated:
/// `sleep(for:)`'s registration, `advance(by:)`'s firing, and cancellation
/// are plain, mutually-exclusive operations on a shared data structure, so
/// none of them depend on which executor or priority queue a caller
/// happens to run on.
///
/// `advance(by:)` snapshots and removes every currently-due sleeper in one
/// locked step before resuming any of them, so it only ever fires sleepers
/// that were already registered at the instant it was called — a sleeper a
/// resumed remainder re-registers during the same call can never also fire
/// in it. It returns how many sleepers it actually fired, so a caller that
/// expected more from one call gets a wrong number back, not silence. A
/// caller that needs several ticks calls `advance(by:)` then `await
/// clock.waitForSleepers(1)` once per tick — a real registration event,
/// resumed synchronously under the same lock the instant the requested
/// count is reached, not a guess at scheduling order.
///
/// `sleep(for:)` wraps its continuation in `withTaskCancellationHandler`,
/// so cancelling the caller removes and resumes its sleeper immediately —
/// matching `SystemClock`'s real `Task.sleep`, which wakes promptly on
/// cancellation instead of waiting out its duration. Registration itself
/// also checks `Task.isCancelled` under the same lock the cancellation
/// handler uses, so a task already cancelled by the time it registers (or
/// cancelled in the narrow window between the handler installing and
/// registration taking the lock) still resumes immediately rather than
/// parking forever — both paths take the same lock, so exactly one of them
/// ever resumes a given sleeper.
///
/// Direct coverage, including a lower-priority sleeper, real async work
/// between ticks, several concurrent sleepers, and cancellation (including
/// the already-cancelled and cancel-racing-registration cases), lives in
/// `TestClockTests.swift`.
nonisolated final class TestClock: SchedulingClock, @unchecked Sendable {
    private struct Sleeper {
        let id: UUID
        let deadlineNanoseconds: Int64
        let continuation: CheckedContinuation<Void, Never>
    }

    /// A pending `waitForSleepers(_:)` call, resumed once `sleepers.count`
    /// reaches `threshold`.
    private struct RegistrationWaiter {
        let threshold: Int
        let resume: () -> Void
    }

    private let lock = NSLock()
    private let epoch: Date
    /// Virtual time since `epoch`, kept as exact integer nanoseconds rather
    /// than `Date`/`Double` arithmetic: repeated `Double` addition
    /// accumulates floating-point error, so a `Double`-seconds
    /// representation can silently drift a deadline comparison off by a
    /// tick. Integer nanosecond comparison has no such drift.
    private var elapsedNanoseconds: Int64 = 0
    private var sleepers: [Sleeper] = []
    private var registrationWaiters: [UUID: RegistrationWaiter] = [:]

    init(now: Date = Date(timeIntervalSince1970: 0)) {
        self.epoch = now
    }

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return epoch.addingTimeInterval(Double(elapsedNanoseconds) / 1_000_000_000)
    }

    /// How many callers are currently suspended in `sleep(for:)` — the
    /// "nothing is scheduled" proof. A hidden/torn-down pane that correctly
    /// cancels its periodic task leaves this at 0 *immediately*,
    /// synchronously as part of the `Task.cancel()` call that cancelled it
    /// — not eventually, once some later `advance(by:)` happens to reach
    /// its deadline. Cancellation is only ever observed here as "removed,"
    /// never "briefly still present" — a cancelled sleeper is either
    /// caught by the cancellation handler (if it had already registered)
    /// or never counted at all (if `register` observes the cancellation
    /// first).
    var pendingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return sleepers.count
    }

    /// Suspends until `duration` of this clock's virtual time has passed,
    /// unless the calling `Task` is already cancelled or becomes cancelled
    /// while suspended here, in which case this returns immediately
    /// instead — see `register(id:duration:continuation:)`.
    func sleep(for duration: Duration) async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                register(id: id, duration: duration, continuation: continuation)
            }
        } onCancel: {
            self.cancelSleeper(id: id)
        }
    }

    /// Registering and cancelling both take `lock`, and this checks
    /// `Task.isCancelled` while holding it — so however `sleep(for:)`'s
    /// cancellation handler and this registration interleave, exactly one
    /// of the two ever resumes the continuation. If the handler runs first
    /// (the task was already cancelled, or became cancelled before
    /// registration reached the lock), it finds nothing to remove yet, and
    /// this check catches it here instead — the continuation still hasn't
    /// been resumed by anyone at that point. If this runs first and the
    /// task isn't cancelled yet, the sleeper is appended normally, and a
    /// cancellation arriving afterward is handled by
    /// `cancelSleeper(id:)` finding and removing it.
    private func register(id: UUID, duration: Duration, continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        if Task.isCancelled {
            lock.unlock()
            continuation.resume()
            return
        }
        let deadline = elapsedNanoseconds + duration.exactNanoseconds
        sleepers.append(Sleeper(id: id, deadlineNanoseconds: deadline, continuation: continuation))
        let satisfied = takeSatisfiedRegistrationWaitersLocked()
        lock.unlock()
        for waiter in satisfied { waiter() }
    }

    private func cancelSleeper(id: UUID) {
        lock.lock()
        guard let index = sleepers.firstIndex(where: { $0.id == id }) else {
            lock.unlock()
            return
        }
        let sleeper = sleepers.remove(at: index)
        lock.unlock()
        sleeper.continuation.resume()
    }

    /// Fires every sleeper already registered whose deadline falls within
    /// `duration` of virtual time from now, in deadline order, and returns
    /// how many fired. All due sleepers are captured — and removed from
    /// `sleepers` — in one locked step before any of them is resumed, so a
    /// sleeper a resumed remainder re-registers during this same call can
    /// never also fire in it: only sleepers already registered when this
    /// was called are eligible. `now` reflects the new target as soon as
    /// this returns, not incrementally, one step per fired sleeper.
    @discardableResult
    func advance(by duration: Duration) async -> Int {
        let due = popAllDueSleepers(advancingBy: duration)
        for sleeper in due {
            sleeper.continuation.resume()
        }
        return due.count
    }

    private func popAllDueSleepers(advancingBy duration: Duration) -> [Sleeper] {
        lock.lock()
        defer { lock.unlock() }
        let target = elapsedNanoseconds + duration.exactNanoseconds
        var due: [Sleeper] = []
        var remaining: [Sleeper] = []
        for sleeper in sleepers {
            if sleeper.deadlineNanoseconds <= target {
                due.append(sleeper)
            } else {
                remaining.append(sleeper)
            }
        }
        sleepers = remaining
        elapsedNanoseconds = target
        due.sort { $0.deadlineNanoseconds < $1.deadlineNanoseconds }
        return due
    }

    /// Awaits until at least `count` sleepers are currently registered — a
    /// real event (resumed synchronously, under `lock`, from inside
    /// `register(id:duration:continuation:)` the instant the threshold is
    /// met), not a guess at scheduling order. Returns whether the
    /// threshold was actually reached, so a caller — and this type's own
    /// tests — can tell a real registration apart from the hang-guard
    /// `bound` expiring; the bound is a failure guard only, never the
    /// success path.
    @discardableResult
    func waitForSleepers(_ count: Int, bound: TimeInterval = 30) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let once = ResumeOnce(continuation)
            let id = UUID()
            let timeoutWorkItem = DispatchWorkItem { [weak self] in
                self?.removeRegistrationWaiter(id: id)
                once.resume(false)
            }
            once.setOnResumed { timeoutWorkItem.cancel() }
            lock.lock()
            if sleepers.count >= count {
                lock.unlock()
                once.resume(true)
                return
            }
            registrationWaiters[id] = RegistrationWaiter(threshold: count) { once.resume(true) }
            lock.unlock()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + bound, execute: timeoutWorkItem)
        }
    }

    private func removeRegistrationWaiter(id: UUID) {
        lock.lock()
        registrationWaiters.removeValue(forKey: id)
        lock.unlock()
    }

    /// Must be called with `lock` already held; returns (and removes) the
    /// waiters whose threshold `sleepers.count` now satisfies.
    private func takeSatisfiedRegistrationWaitersLocked() -> [() -> Void] {
        var satisfied: [() -> Void] = []
        for (key, waiter) in registrationWaiters where sleepers.count >= waiter.threshold {
            satisfied.append(waiter.resume)
            registrationWaiters.removeValue(forKey: key)
        }
        return satisfied
    }
}

private nonisolated extension Duration {
    /// `TestClock`'s own exact integer conversion — `components` is
    /// (whole seconds, attoseconds), and every duration this file's
    /// callers construct (`.seconds`, `.milliseconds`, ...) has an
    /// attosecond component that is a whole multiple of 1e9, so this
    /// division is always exact, unlike a `Double`-seconds round trip.
    var exactNanoseconds: Int64 {
        let components = self.components
        return components.seconds * 1_000_000_000 + components.attoseconds / 1_000_000_000
    }
}
