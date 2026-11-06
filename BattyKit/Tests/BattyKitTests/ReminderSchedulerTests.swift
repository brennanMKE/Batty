// ReminderSchedulerTests.swift

import AppKit
import Foundation
import Testing
@testable import BattyKit

/// Drives `ReminderScheduler` through `TestClock`: time moves only when a
/// test advances it, and every assertion waits on an event (a sleeper
/// registering, a firing arriving), never on real time.
@MainActor
struct ReminderSchedulerTests {
    private let calendar = ReminderFixture.calendar()

    private func makeScheduler(
        clock: SchedulingClock,
        recorder: FiringRecorder,
        calendar: @escaping () -> Calendar = { ReminderFixture.calendar() }
    ) -> ReminderScheduler {
        ReminderScheduler(clock: clock, calendar: calendar, onFire: { recorder.record($0) })
    }

    private func reminder(_ spec: ReminderSpec, at clock: SchedulingClock, note: String? = nil) throws -> SessionReminder {
        try #require(spec.makeReminder(now: clock.now, calendar: calendar, note: note))
    }

    // MARK: - Presets

    @Test func aFifteenMinuteReminderFiresAtFifteenMinutesAndNotBefore() async throws {
        let clock = TestClock(now: ReminderFixture.anchor)
        let recorder = FiringRecorder()
        let scheduler = makeScheduler(clock: clock, recorder: recorder)
        let sessionID = UUID()
        let made = try reminder(.after(minutes: 15), at: clock, note: "deploy")
        scheduler.set(made, forSessionID: sessionID)

        #expect(await clock.waitForSleepers(1))
        #expect(await clock.advance(by: .seconds(14 * 60 + 59)) == 0)
        #expect(clock.pendingCount == 1)
        #expect(scheduler.pendingCount == 1)

        #expect(await clock.advance(by: .seconds(1)) == 1)
        let firing = try #require(await recorder.next())
        #expect(firing.sessionID == sessionID)
        #expect(firing.reminder == made)
        #expect(firing.dueDate == ReminderFixture.anchor.addingTimeInterval(15 * 60))
        #expect(scheduler.pendingCount == 0)
    }

    @Test func aReminderFiresOnceAndTheLoopGoesIdle() async throws {
        let clock = TestClock(now: ReminderFixture.anchor)
        let recorder = FiringRecorder()
        let scheduler = makeScheduler(clock: clock, recorder: recorder)
        scheduler.set(try reminder(.after(minutes: 5), at: clock), forSessionID: UUID())

        #expect(await clock.waitForSleepers(1))
        await clock.advance(by: .seconds(300))
        _ = try #require(await recorder.next())
        await clock.advance(by: .seconds(3600))
        #expect(clock.pendingCount == 0)
        #expect(scheduler.pendingCount == 0)
    }

    // MARK: - Tomorrow

    @Test func tomorrowAcrossTheFallBackFiresAtFourteenHoursNotThirteen() async throws {
        let now = ReminderFixture.date(2026, 10, 31, 20, 0)
        let clock = TestClock(now: now)
        let recorder = FiringRecorder()
        let scheduler = makeScheduler(clock: clock, recorder: recorder)
        scheduler.set(try reminder(.defaultTomorrow, at: clock), forSessionID: UUID())

        #expect(await clock.waitForSleepers(1))
        #expect(await clock.advance(by: .seconds(13 * 3600)) == 0)
        #expect(await clock.advance(by: .seconds(3600)) == 1)
        let firing = try #require(await recorder.next())
        #expect(firing.dueDate == ReminderFixture.date(2026, 11, 1, 9, 0))
    }

    // MARK: - One per Session, edit, cancel

    @Test func settingASecondReminderReplacesTheFirstSoOnlyTheSecondFires() async throws {
        let clock = TestClock(now: ReminderFixture.anchor)
        let recorder = FiringRecorder()
        let scheduler = makeScheduler(clock: clock, recorder: recorder)
        let sessionID = UUID()
        let first = try reminder(.after(minutes: 10), at: clock, note: "first")
        let second = try reminder(.after(minutes: 20), at: clock, note: "second")
        scheduler.set(first, forSessionID: sessionID)
        #expect(await clock.waitForSleepers(1))
        scheduler.set(second, forSessionID: sessionID)
        #expect(await clock.waitForSleepers(1))

        #expect(scheduler.pendingCount == 1)
        #expect(await clock.advance(by: .seconds(600)) == 0)
        #expect(await clock.advance(by: .seconds(600)) == 1)
        let firing = try #require(await recorder.next())
        #expect(firing.reminder.id == second.id)
        #expect(firing.reminder.note == "second")
    }

    @Test func editingEarlierFiresAtTheNewTime() async throws {
        let clock = TestClock(now: ReminderFixture.anchor)
        let recorder = FiringRecorder()
        let scheduler = makeScheduler(clock: clock, recorder: recorder)
        let sessionID = UUID()
        scheduler.set(try reminder(.after(minutes: 30), at: clock), forSessionID: sessionID)
        #expect(await clock.waitForSleepers(1))
        let moved = try reminder(.after(minutes: 5), at: clock)
        scheduler.set(moved, forSessionID: sessionID)
        #expect(await clock.waitForSleepers(1))

        #expect(await clock.advance(by: .seconds(300)) == 1)
        let firing = try #require(await recorder.next())
        #expect(firing.reminder.id == moved.id)
    }

    @Test func editingLaterMeansItDoesNotFireAtTheOldTime() async throws {
        let clock = TestClock(now: ReminderFixture.anchor)
        let recorder = FiringRecorder()
        let scheduler = makeScheduler(clock: clock, recorder: recorder)
        let sessionID = UUID()
        scheduler.set(try reminder(.after(minutes: 5), at: clock), forSessionID: sessionID)
        #expect(await clock.waitForSleepers(1))
        let moved = try reminder(.after(minutes: 30), at: clock)
        scheduler.set(moved, forSessionID: sessionID)
        #expect(await clock.waitForSleepers(1))

        #expect(await clock.advance(by: .seconds(300)) == 0)
        #expect(await clock.advance(by: .seconds(25 * 60)) == 1)
        let firing = try #require(await recorder.next())
        #expect(firing.reminder.id == moved.id)
    }

    @Test func aCancelledReminderNeverFiresAndLeavesNoSleeper() async throws {
        let clock = TestClock(now: ReminderFixture.anchor)
        let recorder = FiringRecorder()
        let scheduler = makeScheduler(clock: clock, recorder: recorder)
        let cancelled = UUID()
        let sentinel = UUID()
        scheduler.set(try reminder(.after(minutes: 10), at: clock), forSessionID: cancelled)
        #expect(await clock.waitForSleepers(1))
        scheduler.cancel(sessionID: cancelled)

        #expect(clock.pendingCount == 0)
        #expect(scheduler.pendingCount == 0)
        #expect(scheduler.reminder(forSessionID: cancelled) == nil)

        scheduler.set(try reminder(.after(minutes: 120), at: clock), forSessionID: sentinel)
        #expect(await clock.waitForSleepers(1))
        await clock.advance(by: .seconds(7200))
        let firing = try #require(await recorder.next())
        #expect(firing.sessionID == sentinel)
    }

    @Test func cancellingTheLastReminderLeavesTheClockWithNoSleepers() async throws {
        let clock = TestClock(now: ReminderFixture.anchor)
        let scheduler = makeScheduler(clock: clock, recorder: FiringRecorder())
        let sessionID = UUID()
        scheduler.set(try reminder(.after(minutes: 10), at: clock), forSessionID: sessionID)
        #expect(await clock.waitForSleepers(1))
        scheduler.cancel(sessionID: sessionID)
        #expect(clock.pendingCount == 0)
    }

    @Test func remindersOnSeparateSessionsFireInDueOrder() async throws {
        let clock = TestClock(now: ReminderFixture.anchor)
        let recorder = FiringRecorder()
        let scheduler = makeScheduler(clock: clock, recorder: recorder)
        let (a, b) = (UUID(), UUID())
        scheduler.set(try reminder(.after(minutes: 20), at: clock), forSessionID: a)
        scheduler.set(try reminder(.after(minutes: 10), at: clock), forSessionID: b)
        #expect(await clock.waitForSleepers(1))

        await clock.advance(by: .seconds(600))
        #expect(try #require(await recorder.next()).sessionID == b)
        #expect(await clock.waitForSleepers(1))
        await clock.advance(by: .seconds(600))
        #expect(try #require(await recorder.next()).sessionID == a)
    }

    // MARK: - Wake and system changes

    @Test func remindersDueWhileAsleepEachFireOnceInDueOrderOnReevaluate() async throws {
        let clock = WakeableClock(now: ReminderFixture.anchor)
        let recorder = FiringRecorder()
        let scheduler = makeScheduler(clock: clock, recorder: recorder)
        let (late, early, later) = (UUID(), UUID(), UUID())
        scheduler.set(try reminder(.after(minutes: 10), at: clock), forSessionID: late)
        scheduler.set(try reminder(.after(minutes: 5), at: clock), forSessionID: early)
        scheduler.set(try reminder(.after(minutes: 60), at: clock), forSessionID: later)
        #expect(await clock.timers.waitForSleepers(1))

        clock.jump(by: 30 * 60)
        scheduler.reevaluate()

        let first = try #require(await recorder.next())
        let second = try #require(await recorder.next())
        #expect(first.sessionID == early)
        #expect(second.sessionID == late)
        #expect(first.dueDate == ReminderFixture.anchor.addingTimeInterval(5 * 60))
        #expect(second.dueDate == ReminderFixture.anchor.addingTimeInterval(10 * 60))
        #expect(scheduler.pendingCount == 1)

        #expect(await clock.timers.waitForSleepers(1))
        await clock.timers.advance(by: .seconds(30 * 60))
        let third = try #require(await recorder.next())
        #expect(third.sessionID == later)
    }

    /// The pending sleep never resumes here (the timers are not advanced), so
    /// only the wake notification can make the overdue Reminder fire.
    @Test func theWakeNotificationFiresATomorrowReminderTheMacSleptThrough() async throws {
        let clock = WakeableClock(now: ReminderFixture.anchor)
        let recorder = FiringRecorder()
        let scheduler = makeScheduler(clock: clock, recorder: recorder)
        let workspaceCenter = NotificationCenter()
        let systemCenter = NotificationCenter()
        scheduler.observeSystemEvents(workspaceCenter: workspaceCenter, systemCenter: systemCenter)
        defer { scheduler.stopObservingSystemEvents() }
        let sessionID = UUID()
        let made = try reminder(.defaultTomorrow, at: clock, note: "check on PRs")
        scheduler.set(made, forSessionID: sessionID)
        #expect(await clock.timers.waitForSleepers(1))

        // Asleep overnight: the Mac wakes at 07:15 the day after the 9:00 due time.
        let due = ReminderFixture.date(2026, 10, 15, 9, 0)
        clock.jump(by: ReminderFixture.date(2026, 10, 16, 7, 15).timeIntervalSince(clock.now))
        workspaceCenter.post(name: NSWorkspace.didWakeNotification, object: nil)

        let firing = try #require(await recorder.next())
        #expect(firing.sessionID == sessionID)
        #expect(firing.reminder.note == "check on PRs")
        #expect(firing.dueDate == due)
        #expect(scheduler.pendingCount == 0)
    }

    @Test func aTomorrowReminderMovesWithTheTimeZoneOnReevaluate() async throws {
        let clock = WakeableClock(now: ReminderFixture.anchor)
        let recorder = FiringRecorder()
        var zone = ReminderFixture.zone
        let scheduler = makeScheduler(clock: clock, recorder: recorder, calendar: { ReminderFixture.calendar(in: zone) })
        let sessionID = UUID()
        scheduler.set(try reminder(.defaultTomorrow, at: clock), forSessionID: sessionID)
        #expect(await clock.timers.waitForSleepers(1))

        // 06:30 PDT on the 15th: before 9:00 PDT, but after 9:00 EDT.
        clock.jump(by: ReminderFixture.date(2026, 10, 15, 6, 30).timeIntervalSince(clock.now))
        zone = TimeZone(identifier: "America/New_York")!
        scheduler.reevaluate()

        let firing = try #require(await recorder.next())
        #expect(firing.sessionID == sessionID)
        #expect(firing.dueDate == ReminderFixture.date(2026, 10, 15, 9, 0, in: zone))
    }

    @Test func anInstantReminderDoesNotMoveWithTheTimeZone() async throws {
        let clock = WakeableClock(now: ReminderFixture.anchor)
        let recorder = FiringRecorder()
        var zone = ReminderFixture.zone
        let scheduler = makeScheduler(clock: clock, recorder: recorder, calendar: { ReminderFixture.calendar(in: zone) })
        let instant = UUID()
        let sentinel = UUID()
        scheduler.set(try reminder(.after(minutes: 600), at: clock), forSessionID: instant)
        #expect(await clock.timers.waitForSleepers(1))

        zone = TimeZone(identifier: "Asia/Tokyo")!
        scheduler.reevaluate()
        scheduler.set(try reminder(.after(minutes: 700), at: clock), forSessionID: sentinel)
        #expect(await clock.timers.waitForSleepers(1))

        await clock.timers.advance(by: .seconds(600 * 60))
        let firing = try #require(await recorder.next())
        #expect(firing.sessionID == instant)
        #expect(firing.dueDate == ReminderFixture.anchor.addingTimeInterval(600 * 60))
    }
}
