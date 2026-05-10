// BellFeedStore.swift

import Foundation
import Observation

@Observable
@MainActor
public final class BellFeedStore {
    public static let cap: Int = 200

    public internal(set) var entries: [BellFeedEntry] = []

    public init(entries: [BellFeedEntry] = []) {
        self.entries = entries.sorted { $0.timestamp > $1.timestamp }
        if self.entries.count > Self.cap {
            self.entries.removeLast(self.entries.count - Self.cap)
        }
    }

    @discardableResult
    public func record(_ entry: BellFeedEntry) -> BellFeedEntry {
        entries.insert(entry, at: 0)
        if entries.count > Self.cap {
            entries.removeLast(entries.count - Self.cap)
        }
        return entry
    }

    public func markSeen(id: UUID) -> BellFeedEntry? {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return nil }
        guard !entries[index].seen else { return entries[index] }
        entries[index].seen = true
        return entries[index]
    }

    @discardableResult
    public func markAllSeen() -> [BellFeedEntry] {
        let touched = entries.enumerated().compactMap { idx, entry -> BellFeedEntry? in
            guard !entry.seen else { return nil }
            entries[idx].seen = true
            return entries[idx]
        }
        return touched
    }

    public var unseenCount: Int {
        entries.lazy.filter { !$0.seen }.count
    }

    public func unseenCount(forTabID tabID: UUID) -> Int {
        entries.lazy.filter { !$0.seen && $0.tabID == tabID }.count
    }

    public func unseenCount(forPaneID paneID: UUID) -> Int {
        entries.lazy.filter { !$0.seen && $0.paneID == paneID }.count
    }

    public func unseenCount(forSessionID sessionID: UUID) -> Int {
        entries.lazy.filter { !$0.seen && $0.sessionID == sessionID }.count
    }
}
