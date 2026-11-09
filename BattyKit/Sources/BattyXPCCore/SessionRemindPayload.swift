// SessionRemindPayload.swift

import Foundation

/// Request/reply payloads for the `sessionRemind` XPC verb (#0567).
/// `nonisolated` at the type level for the same reason as every other
/// payload in this module: the package's default MainActor isolation would
/// otherwise make the synthesized `Codable` conformances main-actor-only.

/// A 24-hour wall-clock time for `--tomorrow --at`.
public nonisolated struct SessionRemindTimeOfDay: Codable, Sendable, Equatable {
    public let hour: Int
    public let minute: Int

    public init(hour: Int, minute: Int) {
        self.hour = hour
        self.minute = minute
    }

    /// `H:MM` or `HH:MM`, hour 0-23, minute exactly two digits 0-59.
    public static func parse(_ text: String) -> SessionRemindTimeOfDay? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2,
              (1...2).contains(parts[0].count), parts[1].count == 2,
              parts[0].allSatisfy(\.isASCIIDigit), parts[1].allSatisfy(\.isASCIIDigit),
              let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0...23).contains(hour), (0...59).contains(minute)
        else { return nil }
        return SessionRemindTimeOfDay(hour: hour, minute: minute)
    }
}

public nonisolated enum SessionRemindAction: Codable, Sendable, Equatable {
    case after(minutes: Int)
    /// `time == nil` means "the app's default Tomorrow time", resolved
    /// app-side so the CLI never reads app preferences.
    case tomorrow(time: SessionRemindTimeOfDay?)
    case cancel
}

/// `sessionID == nil` means the CLI's `--session` → `BATTY_SESSION_ID`
/// chain came up empty; the app falls back to its focused Session.
public nonisolated struct SessionRemindRequest: Codable, Sendable, Equatable {
    /// Mirrors `ReminderSpec.minMinutes/maxMinutes`, which the CLI target
    /// cannot import; a unit test pins them equal.
    public static let minMinutes = 1
    public static let maxMinutes = 7 * 24 * 60

    public let sessionID: UUID?
    public let action: SessionRemindAction
    public let note: String?

    public init(sessionID: UUID?, action: SessionRemindAction, note: String?) {
        self.sessionID = sessionID
        self.action = action
        self.note = note
    }

    /// `Nm`, `Nh` or `NhMm` (lowercase; compound minutes 0-59), resolved to
    /// minutes and bounded to `minMinutes...maxMinutes`.
    public static func parseDuration(_ text: String) -> Int? {
        func number(_ s: Substring) -> Int? {
            guard !s.isEmpty, s.allSatisfy(\.isASCIIDigit) else { return nil }
            return Int(s)
        }
        guard text.hasSuffix("m") || text.hasSuffix("h") else { return nil }
        var total: Int
        if let hIndex = text.firstIndex(of: "h") {
            guard let hours = number(text[..<hIndex]) else { return nil }
            let rest = text[text.index(after: hIndex)...]
            var minutes = 0
            if !rest.isEmpty {
                guard rest.hasSuffix("m"), let m = number(rest.dropLast()), m <= 59 else { return nil }
                minutes = m
            }
            let (product, overflow) = hours.multipliedReportingOverflow(by: 60)
            guard !overflow else { return nil }
            total = product + minutes
        } else {
            guard let minutes = number(text.dropLast()) else { return nil }
            total = minutes
        }
        guard (minMinutes...maxMinutes).contains(total) else { return nil }
        return total
    }
}

/// `reminder` is nil after `cancel`.
public nonisolated struct SessionRemindReply: Codable, Sendable, Equatable {
    public let sessionID: UUID
    public let reminder: TopologyReminderPayload?

    public init(sessionID: UUID, reminder: TopologyReminderPayload?) {
        self.sessionID = sessionID
        self.reminder = reminder
    }
}

private extension Character {
    nonisolated var isASCIIDigit: Bool { isASCII && isNumber }
}
