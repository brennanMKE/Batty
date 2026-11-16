// SessionReminder.swift

import Foundation

/// A one-shot timer attached to one Session (`Concepts.md`: Reminder). A pure
/// value: no view, AppKit or libghostty types.
nonisolated public struct SessionReminder: Sendable, Equatable, Identifiable {
    public enum Target: Sendable, Equatable {
        /// Presets and custom durations: resolved once, when set, so a
        /// time-zone or DST change never moves the fire time.
        case instant(Date)
        /// Tomorrow: year, month, day, hour and minute in the user's
        /// calendar, re-resolved against the current calendar and time zone
        /// every time the scheduler evaluates.
        case wallClock(DateComponents)
    }

    public static let maxNoteLength = 500

    public let id: UUID
    public let createdAt: Date
    public var target: Target
    public var note: String?

    public init(id: UUID = UUID(), createdAt: Date, target: Target, note: String? = nil) {
        self.id = id
        self.createdAt = createdAt
        self.target = target
        self.note = Self.normalizedNote(note)
    }

    /// Trimmed, `nil` when empty, capped at `maxNoteLength` characters.
    public static func normalizedNote(_ note: String?) -> String? {
        guard let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return String(trimmed.prefix(maxNoteLength))
    }

    /// What the Reminder says when it fires: its note, or "Come back to
    /// <Session>" when it has none.
    public func displayText(sessionTitle: String) -> String {
        Self.displayText(note: note, sessionTitle: sessionTitle)
    }

    public static func displayText(note: String?, sessionTitle: String) -> String {
        if let note = normalizedNote(note) { return note }
        return String(localized: "Come back to \(sessionTitle)")
    }

    /// The absolute instant this Reminder is due, or nil when a wall-clock
    /// target names a date the calendar cannot resolve.
    public func fireDate(calendar: Calendar) -> Date? {
        switch target {
        case .instant(let date):
            return date
        case .wallClock(let components):
            return calendar.date(from: components)
        }
    }
}

/// A time of day for a Tomorrow Reminder, stored as minutes since midnight.
nonisolated public struct ReminderTime: Sendable, Hashable {
    public var hour: Int
    public var minute: Int

    public init(hour: Int, minute: Int) {
        self.hour = hour
        self.minute = minute
    }

    public static let defaultTomorrow = ReminderTime(
        hour: ReminderSpec.defaultTomorrowHour, minute: ReminderSpec.defaultTomorrowMinute)

    public var minutesSinceMidnight: Int { hour * 60 + minute }

    /// Nil outside `0..<1440`.
    public init?(minutesSinceMidnight: Int) {
        guard (0..<1440).contains(minutesSinceMidnight) else { return nil }
        self.init(hour: minutesSinceMidnight / 60, minute: minutesSinceMidnight % 60)
    }

    public var tomorrowSpec: ReminderSpec { .tomorrow(hour: hour, minute: minute) }
}

/// What the user asked for, before it is resolved against a clock.
nonisolated public enum ReminderSpec: Sendable, Equatable {
    case after(minutes: Int)
    case tomorrow(hour: Int, minute: Int)
    /// A chosen instant, between `minMinutes` and `maxMinutes` after the
    /// moment it is resolved.
    case at(Date)

    public static let minMinutes = 1
    public static let maxMinutes = 7 * 24 * 60
    public static let defaultTomorrowHour = 9
    public static let defaultTomorrowMinute = 0
    public static let presetMinutes: [Int] = [5, 15, 30, 60]

    public var isValid: Bool {
        switch self {
        case .after(let minutes):
            return (Self.minMinutes...Self.maxMinutes).contains(minutes)
        case .tomorrow(let hour, let minute):
            return (0...23).contains(hour) && (0...59).contains(minute)
        case .at:
            return true
        }
    }

    /// Whether an `.at(date)` request is in bounds against `now`.
    public static func isInstantInRange(_ date: Date, now: Date) -> Bool {
        let seconds = date.timeIntervalSince(now)
        return seconds >= TimeInterval(minMinutes * 60) && seconds <= TimeInterval(maxMinutes * 60)
    }

    /// Today at `hour:minute` in `calendar`, or nil when the time is not a
    /// valid clock time or the calendar cannot resolve it.
    public static func todayAt(hour: Int, minute: Int, now: Date, calendar: Calendar) -> Date? {
        guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = hour
        components.minute = minute
        return calendar.date(from: components)
    }

    /// Resolves the request to a Reminder, or nil when it is out of bounds.
    public func makeReminder(
        now: Date,
        calendar: Calendar,
        note: String?,
        id: UUID = UUID()
    ) -> SessionReminder? {
        guard isValid else { return nil }
        switch self {
        case .after(let minutes):
            return SessionReminder(
                id: id,
                createdAt: now,
                target: .instant(now.addingTimeInterval(TimeInterval(minutes) * 60)),
                note: note)
        case .tomorrow(let hour, let minute):
            return SessionReminder(
                id: id,
                createdAt: now,
                target: .wallClock(Self.tomorrowComponents(now: now, calendar: calendar, hour: hour, minute: minute)),
                note: note)
        case .at(let date):
            guard Self.isInstantInRange(date, now: now) else { return nil }
            return SessionReminder(id: id, createdAt: now, target: .instant(date), note: note)
        }
    }

    /// The next calendar day after `now`'s, at `hour:minute`. A `now` of
    /// 00:30 still resolves to the *next* day, never later the same day.
    static func tomorrowComponents(now: Date, calendar: Calendar, hour: Int, minute: Int) -> DateComponents {
        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? today.addingTimeInterval(86_400)
        var components = calendar.dateComponents([.year, .month, .day], from: tomorrow)
        components.hour = hour
        components.minute = minute
        return components
    }
}

/// User-facing wording for a Reminder's due time. Everything takes the
/// calendar, locale and `now` as parameters so the result never depends on
/// the machine running the code.
nonisolated public enum ReminderFormat {
    /// A Reminder delivered more than this long after it was due is late.
    public static let lateAfter: TimeInterval = 60

    public static func time(_ date: Date, calendar: Calendar = .current, locale: Locale = .autoupdatingCurrent) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar, timeZone: calendar.timeZone))
    }

    /// Weekday, date and time, always absolute: "Thu, Oct 15 at 9:00 AM".
    public static func absolute(_ date: Date, calendar: Calendar = .current, locale: Locale = .autoupdatingCurrent) -> String {
        date.formatted(
            Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
                .weekday(.abbreviated).month(.abbreviated).day().hour().minute())
    }

    /// "at 3:45 PM" today, "tomorrow at 9:00 AM" the next calendar day, and
    /// the absolute form for anything later.
    public static func phrase(
        for date: Date,
        now: Date,
        calendar: Calendar = .current,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        let clock = time(date, calendar: calendar, locale: locale)
        if calendar.isDate(date, inSameDayAs: now) {
            return String(localized: "at \(clock)")
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return String(localized: "tomorrow at \(clock)")
        }
        return String(localized: "on \(absolute(date, calendar: calendar, locale: locale))")
    }

    /// A pending Reminder's relative time: "in N min" up to an
    /// hour (rounded up, at least 1), then the `phrase(for:now:)` wording.
    public static func relativeLine(
        due: Date,
        now: Date,
        calendar: Calendar = .current,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        let seconds = due.timeIntervalSince(now)
        if seconds <= 60 * 60 {
            let minutes = max(1, Int((seconds / 60).rounded(.up)))
            return String(localized: "in \(minutes) min")
        }
        return phrase(for: due, now: now, calendar: calendar, locale: locale)
    }

    /// A due Reminder's relative time: "due just now", "due N min
    /// ago", then "due at <time>" after an hour.
    public static func dueLine(
        dueAt: Date,
        now: Date,
        calendar: Calendar = .current,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        let seconds = now.timeIntervalSince(dueAt)
        if seconds < 60 {
            return String(localized: "due just now")
        }
        if seconds < 60 * 60 {
            return String(localized: "due \(Int(seconds / 60)) min ago")
        }
        return String(localized: "due at \(time(dueAt, calendar: calendar, locale: locale))")
    }

    /// A Reminder notification's body: "Set at <time>", or "Due at <time>"
    /// when it is delivered more than `lateAfter` after it was due.
    public static func notificationBody(
        setAt: Date,
        dueAt: Date,
        deliveredAt: Date,
        calendar: Calendar = .current,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        if deliveredAt.timeIntervalSince(dueAt) > lateAfter {
            return String(localized: "Due at \(time(dueAt, calendar: calendar, locale: locale))")
        }
        return String(localized: "Set at \(time(setAt, calendar: calendar, locale: locale))")
    }
}
