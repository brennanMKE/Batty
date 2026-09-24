// ResumeOnce.swift

import Foundation

/// Guarantees a `CheckedContinuation` is resumed exactly once even though
/// two different callers can race to resume it — a real completion event
/// and a hang-guard timeout, in every use of this type in this test target
/// (`TestClock`, `TestTeardownReapGate`, `ChildProcessReadiness`).
///
/// `setOnResumed(_:)` lets the winner cancel the loser's now-unnecessary
/// pending work (typically a scheduled `DispatchWorkItem`). It must be
/// called, if at all, before this instance is shared with any second party
/// — inserted into a waiter registry, installed as a readability handler,
/// scheduled as a dispatch timeout — never after. Every caller in this
/// file's users follows the same shape to guarantee that ordering: build
/// whatever the cleanup closure needs to reference first, wire it via
/// `setOnResumed`, and only then publish this instance. Publishing first
/// and wiring the cleanup after would let a concurrent `resume()` read
/// `onResumed` before the write lands — the lock here protects this
/// instance's own storage from a torn read/write of that assignment, but
/// it cannot retroactively fix a caller that publishes before wiring.
nonisolated final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false
    private let continuation: CheckedContinuation<T, Never>
    private var onResumed: (() -> Void)?

    init(_ continuation: CheckedContinuation<T, Never>) {
        self.continuation = continuation
    }

    func setOnResumed(_ callback: @escaping () -> Void) {
        lock.lock()
        onResumed = callback
        lock.unlock()
    }

    func resume(_ value: T) {
        lock.lock()
        guard !resumed else {
            lock.unlock()
            return
        }
        resumed = true
        let callback = onResumed
        lock.unlock()
        continuation.resume(returning: value)
        callback?()
    }
}
