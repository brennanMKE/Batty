// AwaitBounded.swift

import Foundation

/// Races `operation` against a hang-guard timeout. The timeout is only a
/// failure guard; the real completion signal is the operation itself.
nonisolated func awaitBounded(
    bound: TimeInterval = TestBounds.hangGuard,
    _ operation: @escaping @Sendable () async -> Void
) async -> Bool {
    await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
        let once = ResumeOnce(continuation)
        let timeout = DispatchWorkItem { once.resume(false) }
        once.setOnResumed { timeout.cancel() }
        Task {
            await operation()
            once.resume(true)
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + bound, execute: timeout)
    }
}
