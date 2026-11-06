// ManualSchedulingClock.swift

import Foundation

/// A `SchedulingClock` whose time passes only when `advance(by:)` is called.
/// Used under the UI-test launch (`UITestDriver.reminderClock(environment:)`)
/// so a UI test can fire a Reminder without waiting for real time. Unit tests
/// use `TestClock` instead, which also offers sleeper-registration signals.
///
/// Lock-guarded rather than actor-isolated for the same reason as
/// `SystemClock`: `SchedulingClock` is `nonisolated`, and a cancelled sleeper
/// must be removed and resumed from the cancellation handler without an
/// actor hop.
public nonisolated final class ManualSchedulingClock: SchedulingClock, @unchecked Sendable {
    private struct Sleeper {
        let id: UUID
        let deadline: TimeInterval
        let continuation: CheckedContinuation<Void, Never>
    }

    private let lock = NSLock()
    private let start: Date
    private var elapsed: TimeInterval = 0
    private var sleepers: [Sleeper] = []

    public init(start: Date = Date()) {
        self.start = start
    }

    public var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return start.addingTimeInterval(elapsed)
    }

    public func sleep(for duration: Duration) async {
        let id = UUID()
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                if Task.isCancelled {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                sleepers.append(Sleeper(id: id, deadline: elapsed + seconds, continuation: continuation))
                lock.unlock()
            }
        } onCancel: {
            lock.lock()
            let index = sleepers.firstIndex { $0.id == id }
            let sleeper = index.map { sleepers.remove(at: $0) }
            lock.unlock()
            sleeper?.continuation.resume()
        }
    }

    /// Moves time forward and resumes every sleeper whose deadline has been
    /// reached, earliest first.
    public func advance(by seconds: TimeInterval) {
        lock.lock()
        elapsed += seconds
        let due = sleepers.filter { $0.deadline <= elapsed }.sorted { $0.deadline < $1.deadline }
        sleepers.removeAll { $0.deadline <= elapsed }
        lock.unlock()
        for sleeper in due { sleeper.continuation.resume() }
    }
}
