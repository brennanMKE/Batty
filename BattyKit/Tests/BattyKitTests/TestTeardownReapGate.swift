// TestTeardownReapGate.swift

import Foundation
@testable import BattyKit

/// A `TeardownReapGate` a test can hold closed, then open explicitly — lets
/// a test prove a deferred reap task genuinely didn't run yet, rather than
/// guessing from elapsed time. `nonisolated`/`@unchecked Sendable` + lock:
/// `waitUntilOpen()` is called from the `Task.detached` closure it gates,
/// off the main actor, the same shape `PendingTeardownReapRegistry` uses
/// for its own cross-actor state.
nonisolated final class TestTeardownReapGate: TeardownReapGate, @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    /// A pending `waitForParkedWaiter` call, resumed once `waiters.count`
    /// reaches `threshold`. A closed gate only proves something if a
    /// caller is actually parked on it — checking `waiters.count` directly
    /// is how a test confirms that, instead of assuming a closed gate
    /// implies a waiter exists.
    private var parkWaiters: [UUID: (threshold: Int, resume: () -> Void)] = [:]

    func waitUntilOpen() async {
        // `NSLock.lock()`/`unlock()` are unavailable from `async` contexts
        // (compiler-enforced, so a suspension can never land mid-critical-
        // section) — `withLock` is the async-safe scoped form. Checking
        // `isOpen` again inside the continuation's own registration closure
        // (rather than trusting a check made before `withCheckedContinuation`
        // started) closes the race against a concurrent `open()`: no window
        // exists where `open()` could run between "checked, not open yet"
        // and "registered as a waiter."
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let toNotify: [() -> Void] = lock.withLock {
                if isOpen {
                    continuation.resume()
                    return []
                }
                waiters.append(continuation)
                return takeSatisfiedParkWaitersLocked()
            }
            for notify in toNotify { notify() }
        }
    }

    /// Opens the gate, resuming every task currently suspended in
    /// `waitUntilOpen()` and letting every future call return immediately.
    func open() {
        let toResume = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            isOpen = true
            let waiting = waiters
            waiters.removeAll()
            return waiting
        }
        for waiter in toResume {
            waiter.resume()
        }
    }

    /// Awaits until at least `count` callers are currently parked in
    /// `waitUntilOpen()` — a real event, resumed the instant the threshold
    /// is met. Returns whether the threshold was actually reached, so a
    /// caller can tell a real parked waiter apart from the hang-guard
    /// `bound` expiring; the bound is a failure guard only, never the
    /// success path.
    @discardableResult
    func waitForParkedWaiter(_ count: Int = 1, bound: TimeInterval = 30) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let once = ResumeOnce(continuation)
            let id = UUID()
            let timeoutWorkItem = DispatchWorkItem { [weak self] in
                self?.removeParkWaiter(id: id)
                once.resume(false)
            }
            once.setOnResumed { timeoutWorkItem.cancel() }
            lock.lock()
            if waiters.count >= count {
                lock.unlock()
                once.resume(true)
                return
            }
            parkWaiters[id] = (threshold: count, resume: { once.resume(true) })
            lock.unlock()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + bound, execute: timeoutWorkItem)
        }
    }

    private func removeParkWaiter(id: UUID) {
        lock.lock()
        parkWaiters.removeValue(forKey: id)
        lock.unlock()
    }

    /// Must be called with `lock` already held; returns (and removes) the
    /// `waitForParkedWaiter` resume closures whose threshold `waiters.count`
    /// now satisfies.
    private func takeSatisfiedParkWaitersLocked() -> [() -> Void] {
        var satisfied: [() -> Void] = []
        for (key, waiter) in parkWaiters where waiters.count >= waiter.threshold {
            satisfied.append(waiter.resume)
            parkWaiters.removeValue(forKey: key)
        }
        return satisfied
    }
}
