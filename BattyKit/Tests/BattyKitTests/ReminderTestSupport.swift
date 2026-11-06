// ReminderTestSupport.swift

import Foundation
@testable import BattyKit

/// Fixed anchor for Reminder tests: 2026-10-14 15:00:00 in America/Los_Angeles
/// (PDT, UTC-7), a non-default instant so nothing passes by matching
/// `Date(timeIntervalSince1970: 0)`.
nonisolated enum ReminderFixture {
    static let zone = TimeZone(identifier: "America/Los_Angeles")!

    static func calendar(in zone: TimeZone = ReminderFixture.zone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }

    static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, in zone: TimeZone = ReminderFixture.zone) -> Date {
        let components = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
        return calendar(in: zone).date(from: components)!
    }

    static var anchor: Date { date(2026, 10, 14, 15, 0) }
}

/// Collects `ReminderFiring`s as events a test awaits, instead of waiting for
/// time to pass. `next()` has an upper bound so a regression fails instead of
/// hanging; the bound is never how a passing run completes.
@MainActor
final class FiringRecorder {
    private var buffer: [ReminderFiring] = []
    private var waiter: (id: UUID, continuation: CheckedContinuation<ReminderFiring?, Never>)?

    func record(_ firing: ReminderFiring) {
        if let waiter {
            self.waiter = nil
            waiter.continuation.resume(returning: firing)
        } else {
            buffer.append(firing)
        }
    }

    func next(bound: TimeInterval = TestBounds.hangGuard) async -> ReminderFiring? {
        if !buffer.isEmpty { return buffer.removeFirst() }
        let id = UUID()
        let guardTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(bound))
            guard !Task.isCancelled else { return }
            self?.expire(id)
        }
        defer { guardTask.cancel() }
        return await withCheckedContinuation { continuation in
            waiter = (id, continuation)
        }
    }

    private func expire(_ id: UUID) {
        guard let waiter, waiter.id == id else { return }
        self.waiter = nil
        waiter.continuation.resume(returning: nil)
    }
}

/// A `SchedulingClock` whose `now` can be moved without releasing any
/// sleeper, the shape of a Mac that slept through its timers: the timers did
/// not fire, but the wall clock is later when it wakes. Sleeping delegates to
/// a `TestClock`, so cancellation and registration signals work unchanged.
nonisolated final class WakeableClock: SchedulingClock, @unchecked Sendable {
    let timers: TestClock
    private let lock = NSLock()
    private var jumped: TimeInterval = 0

    init(now: Date) {
        timers = TestClock(now: now)
    }

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return timers.now.addingTimeInterval(jumped)
    }

    func sleep(for duration: Duration) async {
        await timers.sleep(for: duration)
    }

    func jump(by seconds: TimeInterval) {
        lock.lock()
        jumped += seconds
        lock.unlock()
    }
}
