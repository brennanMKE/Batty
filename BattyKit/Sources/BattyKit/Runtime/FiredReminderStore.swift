// FiredReminderStore.swift

import Foundation
import Observation

/// A Session Reminder that came due. In memory only, like the Bell Feed.
nonisolated public struct FiredReminder: Sendable, Hashable, Identifiable {
    /// The Reminder's own id.
    public var id: UUID
    public var sessionID: UUID
    /// The Window that owned the Session at fire time. Nothing routes by it.
    public var windowID: UUID
    public var note: String?
    public var createdAt: Date
    public var dueAt: Date
    /// Later than `dueAt` by more than a moment when the Mac slept through it.
    public var firedAt: Date
    public var seen: Bool

    public init(
        id: UUID,
        sessionID: UUID,
        windowID: UUID,
        note: String?,
        createdAt: Date,
        dueAt: Date,
        firedAt: Date,
        seen: Bool = false
    ) {
        self.id = id
        self.sessionID = sessionID
        self.windowID = windowID
        self.note = note
        self.createdAt = createdAt
        self.dueAt = dueAt
        self.firedAt = firedAt
        self.seen = seen
    }

    public func displayText(sessionTitle: String) -> String {
        SessionReminder.displayText(note: note, sessionTitle: sessionTitle)
    }
}

/// Fired Reminders, newest first, at most one per Session. Separate from the
/// Bell Feed: nothing here lights the bell.
@Observable
@MainActor
public final class FiredReminderStore {
    public internal(set) var items: [FiredReminder] = [] {
        didSet { refreshAggregates() }
    }

    /// Stored so a write that changes none of them doesn't invalidate their
    /// readers. Each is written only when its value differs.
    public private(set) var unseenCount: Int = 0
    public private(set) var readCount: Int = 0
    /// Sessions with an unread fired Reminder.
    public private(set) var unseenSessionIDs: Set<UUID> = []

    public init() {}

    private func refreshAggregates() {
        var unseen: Set<UUID> = []
        var unseenTotal = 0
        for item in items where !item.seen {
            unseenTotal += 1
            unseen.insert(item.sessionID)
        }
        if unseenTotal != unseenCount { unseenCount = unseenTotal }
        let read = items.count - unseenTotal
        if read != readCount { readCount = read }
        if unseen != unseenSessionIDs { unseenSessionIDs = unseen }
    }

    // Every mutator below skips the write when nothing matches: an in-place
    // mutation (`items[i].seen = true`, `items.removeAll`) notifies even
    // when it changes nothing, and
    // `markSeen(sessionID:)` and `remove(sessionID:)` run on every selection
    // and every visit (#0556).

    /// Replaces any item of the same Session, in one whole-array write.
    public func record(_ fired: FiredReminder) {
        var next = items
        next.removeAll { $0.sessionID == fired.sessionID }
        next.insert(fired, at: 0)
        items = next
    }

    public func item(forSessionID sessionID: UUID) -> FiredReminder? {
        items.first { $0.sessionID == sessionID }
    }

    /// True when an unread item was marked read.
    @discardableResult
    public func markSeen(sessionID: UUID) -> Bool {
        guard let index = items.firstIndex(where: { $0.sessionID == sessionID && !$0.seen }) else { return false }
        items[index].seen = true
        return true
    }

    /// True when an unread item was marked read.
    @discardableResult
    public func markSeen(id: UUID) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == id && !$0.seen }) else { return false }
        items[index].seen = true
        return true
    }

    /// The items that were unread.
    @discardableResult
    public func markAllSeen() -> [FiredReminder] {
        let touched = items.filter { !$0.seen }
        guard !touched.isEmpty else { return [] }
        items = items.map { item in
            var item = item
            item.seen = true
            return item
        }
        return touched.map { item in
            var item = item
            item.seen = true
            return item
        }
    }

    @discardableResult
    public func remove(sessionID: UUID) -> FiredReminder? {
        guard let index = items.firstIndex(where: { $0.sessionID == sessionID }) else { return nil }
        return items.remove(at: index)
    }

    @discardableResult
    public func remove(id: UUID) -> FiredReminder? {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        return items.remove(at: index)
    }

    /// Clear Read: drops every read item.
    @discardableResult
    public func removeReadEntries() -> [FiredReminder] {
        let removed = items.filter(\.seen)
        guard !removed.isEmpty else { return [] }
        items.removeAll(where: \.seen)
        return removed
    }
}
