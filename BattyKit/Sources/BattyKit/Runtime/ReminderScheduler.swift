// ReminderScheduler.swift

import AppKit
import Foundation
import OSLog

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "ReminderScheduler")

/// One Reminder that has come due.
public struct ReminderFiring: Sendable, Equatable {
    public let sessionID: UUID
    public let reminder: SessionReminder
    /// The instant the Reminder was due. Earlier than the clock's `now` when
    /// the Mac slept through it.
    public let dueDate: Date
}

/// Holds every pending Reminder app-wide and fires each one when its time
/// comes. A single loop task sleeps until the earliest due date; `set`,
/// `cancel` and `reevaluate()` restart it, so the loop never relies on a
/// pending sleep resuming promptly after the Mac wakes.
///
/// The clock and calendar are injected (`docs/async-test-seams.md` §1). The
/// calendar is a provider read on every evaluation, so a time-zone change
/// moves a Tomorrow Reminder with the wall clock.
@MainActor
public final class ReminderScheduler {
    private let clock: SchedulingClock
    private let calendarProvider: () -> Calendar
    public var onFire: (ReminderFiring) -> Void
    private var pending: [UUID: SessionReminder] = [:]
    private var loopTask: Task<Void, Never>?
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []

    public init(
        clock: SchedulingClock = SystemClock(),
        calendar: @escaping () -> Calendar = { .current },
        onFire: @escaping (ReminderFiring) -> Void = { _ in }
    ) {
        self.clock = clock
        self.calendarProvider = calendar
        self.onFire = onFire
    }

    public var now: Date { clock.now }
    public var calendar: Calendar { calendarProvider() }
    public var pendingCount: Int { pending.count }

    /// The frozen clock a UI-test launch installs, nil on any other clock.
    /// The test-only Command Palette entries advance it.
    var manualClock: ManualSchedulingClock? { clock as? ManualSchedulingClock }

    public func reminder(forSessionID sessionID: UUID) -> SessionReminder? {
        pending[sessionID]
    }

    /// Sets or replaces the Session's Reminder: one per Session. Also the
    /// edit path, since an edit is a replacement that is rescheduled.
    public func set(_ reminder: SessionReminder, forSessionID sessionID: UUID) {
        pending[sessionID] = reminder
        restart()
    }

    public func cancel(sessionID: UUID) {
        guard pending.removeValue(forKey: sessionID) != nil else { return }
        restart()
    }

    /// Recomputes every due date against the current clock and calendar and
    /// fires whatever is already due. The single entry point for the wake
    /// and clock-change observers; tests call it directly to simulate wake.
    public func reevaluate() {
        restart()
    }

    /// Re-evaluates when the Mac wakes, the system clock is set, the time
    /// zone changes, or the calendar day rolls over. Not started by `init`,
    /// so constructing a store in a test never subscribes to system events.
    /// The centers are injectable so a test can post the wake notification
    /// on a private center instead of the system's.
    public func observeSystemEvents(
        workspaceCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        systemCenter: NotificationCenter = .default
    ) {
        guard observers.isEmpty else { return }
        let entries: [(NotificationCenter, Notification.Name)] = [
            (workspaceCenter, NSWorkspace.didWakeNotification),
            (systemCenter, .NSSystemClockDidChange),
            (systemCenter, .NSSystemTimeZoneDidChange),
            (systemCenter, .NSCalendarDayChanged),
        ]
        for (center, name) in entries {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    // `TimeZone.current` is a cached snapshot; refresh it so
                    // the calendar provider sees the new zone.
                    if name == .NSSystemTimeZoneDidChange { NSTimeZone.resetSystemTimeZone() }
                    self?.reevaluate()
                }
            }
            observers.append((center, token))
        }
    }

    func stopObservingSystemEvents() {
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
    }

    private func restart() {
        loopTask?.cancel()
        loopTask = nil
        guard !pending.isEmpty else { return }
        loopTask = Task { [weak self, clock] in
            while !Task.isCancelled {
                let delay: Duration? = { () -> Duration? in
                    guard let self else { return nil }
                    return self.fireDueAndTimeUntilNext()
                }()
                guard let delay else { return }
                await clock.sleep(for: delay)
            }
        }
    }

    private func resolved() -> [(sessionID: UUID, reminder: SessionReminder, due: Date)] {
        let calendar = calendarProvider()
        var items: [(sessionID: UUID, reminder: SessionReminder, due: Date)] = []
        var unresolvable: [UUID] = []
        for (sessionID, reminder) in pending {
            if let due = reminder.fireDate(calendar: calendar) {
                items.append((sessionID, reminder, due))
            } else {
                unresolvable.append(sessionID)
            }
        }
        for sessionID in unresolvable {
            logger.error("reminder for session \(sessionID, privacy: .public) has an unresolvable target; dropping it")
            pending.removeValue(forKey: sessionID)
        }
        return items
    }

    /// Fires what is due, then returns how long to sleep until the next
    /// Reminder, or nil when none remain.
    private func fireDueAndTimeUntilNext() -> Duration? {
        fireDue()
        guard let next = resolved().map(\.due).min() else { return nil }
        return .seconds(max(0, next.timeIntervalSince(clock.now)))
    }

    /// Fires every Reminder due at the clock's `now`, earliest first. Each
    /// is removed before `onFire` runs, so a Reminder fires exactly once and
    /// a callback that sets a new one is not fired in the same pass.
    private func fireDue() {
        let current = clock.now
        let due = resolved()
            .filter { $0.due <= current }
            .sorted { $0.due < $1.due }
        for item in due {
            guard pending[item.sessionID]?.id == item.reminder.id else { continue }
            pending.removeValue(forKey: item.sessionID)
            onFire(ReminderFiring(sessionID: item.sessionID, reminder: item.reminder, dueDate: item.due))
        }
    }
}
