// BellFeedStore.swift

import Foundation
import Observation

extension Notification.Name {
    public static let battyToggleBellFeed = Notification.Name("co.sstools.Batty.toggleBellFeed")
}

public struct BellFeedEntry: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var timestamp: Date
    public var windowID: UUID
    public var sessionID: UUID
    public var paneID: UUID
    public var tabID: UUID
    public var surfaceID: UUID
    public var message: String?
    /// AI-generated summary of the notification content. Populated
    /// asynchronously after the entry is recorded; nil until the model
    /// responds or when Foundation Models is unavailable / disabled.
    public var summary: String?
    public var seen: Bool
    /// #0298: how many raw bell/notification occurrences this entry
    /// represents. Starts at 1; `BellFeedStore.recordOrCollapse` increments
    /// it in place instead of appending a new entry when a repeat matches
    /// the collapse rule (same `tabID`, identical `message` including
    /// `nil`-vs-`nil` for bare BEL, still unseen, within
    /// `BellFeedStore.collapseWindow`). `BellFeedStore` itself is never
    /// restored from disk today, but `BellFeedEntry` is still exercised
    /// through raw `JSONDecoder` in tests simulating older data shapes
    /// (`BellNotificationSummaryTests.oldDataWithoutSummaryDecodesSuccessfully`)
    /// — see the custom `init(from:)` below, which defaults a missing key
    /// to 1 the same way `summary` defaults to nil, so decoding data from
    /// before this field existed doesn't throw.
    public var repeatCount: Int
    /// #0298 round 2 (review): the collapse-window anchor. Set once, at
    /// construction, to this entry's own `timestamp`, and never touched
    /// again by `recordOrCollapse` — `timestamp` itself keeps refreshing to
    /// the latest occurrence so the row still surfaces "when did this most
    /// recently happen," but the 30-minute bound is measured against this
    /// fixed point, not the sliding `timestamp`. Anchoring to `timestamp`
    /// (round 1's shape) let a chain of sub-30-minute gaps drift the row's
    /// displayed time arbitrarily far from the event that actually opened
    /// it — reviewer's repro: `8E75F975`'s real four-event chain
    /// (05:58:46 → 06:20:00 → 06:23:32 → 06:44:38) has every consecutive
    /// gap under 30 minutes but spans 45m52s end to end, which is exactly
    /// the "timestamp silently jumps forward" failure the 30-minute bound
    /// exists to prevent (see `collapseWindow`'s doc comment). Same
    /// `init(from:)` forward-compatibility treatment as `repeatCount`:
    /// missing in older-shaped data, defaults to `timestamp`.
    public var firstOccurrenceAt: Date

    /// Sentinel `windowID`/`sessionID`/`paneID`/`tabID`/`surfaceID` for
    /// entries that don't originate from a real Terminal Session — currently
    /// only the memory-footprint warning. Fixed and never produced by
    /// `UUID()`, so `BellFeedView.pathLabel` can tell "system entry" apart
    /// from "the tab this bell came from has since closed" (which shows
    /// "(closed)"). Every routing path that resolves an entry back to a
    /// session/pane/tab (`jumpToBellEntry`, `pathLabel`) already treats an
    /// unresolvable id as a graceful no-op, so this sentinel needs no special
    /// casing anywhere except the label.
    public static let systemID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    public init(
        id: UUID = UUID(),
        timestamp: Date,
        windowID: UUID,
        sessionID: UUID,
        paneID: UUID,
        tabID: UUID,
        surfaceID: UUID,
        message: String? = nil,
        summary: String? = nil,
        seen: Bool = false,
        repeatCount: Int = 1,
        firstOccurrenceAt: Date? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.windowID = windowID
        self.sessionID = sessionID
        self.paneID = paneID
        self.tabID = tabID
        self.surfaceID = surfaceID
        self.message = message
        self.summary = summary
        self.seen = seen
        self.repeatCount = repeatCount
        self.firstOccurrenceAt = firstOccurrenceAt ?? timestamp
    }

    private enum CodingKeys: String, CodingKey {
        case id, timestamp, windowID, sessionID, paneID, tabID, surfaceID, message, summary, seen, repeatCount, firstOccurrenceAt
    }

    /// Manual `Decodable` so a `repeatCount`/`firstOccurrenceAt` key missing
    /// from older-shaped data (from before #0298) defaults to 1 / `timestamp`
    /// instead of throwing `keyNotFound` — the same forward-compatibility
    /// treatment `summary` already gets via its `Optional` type.
    /// `encode(to:)` stays compiler-synthesized: writing a custom
    /// `init(from:)` doesn't disable synthesis of the other `Codable`
    /// requirement.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        windowID = try container.decode(UUID.self, forKey: .windowID)
        sessionID = try container.decode(UUID.self, forKey: .sessionID)
        paneID = try container.decode(UUID.self, forKey: .paneID)
        tabID = try container.decode(UUID.self, forKey: .tabID)
        surfaceID = try container.decode(UUID.self, forKey: .surfaceID)
        message = try container.decodeIfPresent(String.self, forKey: .message)
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
        seen = try container.decode(Bool.self, forKey: .seen)
        repeatCount = try container.decodeIfPresent(Int.self, forKey: .repeatCount) ?? 1
        firstOccurrenceAt = try container.decodeIfPresent(Date.self, forKey: .firstOccurrenceAt) ?? timestamp
    }
}

@Observable
@MainActor
public final class BellFeedStore {
    public static let cap: Int = 200

    /// #0298: the collapse rule's time bound. A repeat matching an existing
    /// unread entry (same `tabID`, identical `message`) collapses into it
    /// only when within this many seconds of that entry's
    /// `firstOccurrenceAt` — a fixed anchor set once when the entry is
    /// first created, not the entry's (repeatedly refreshed) `timestamp`;
    /// beyond it, the repeat posts as its own new entry instead. Chosen
    /// from the real #0297 export (`issues/0298/bell-decisions-2026-08-05.txt`):
    /// finding 5 showed an unbounded rule folding a repeat 3h48m later into
    /// a pre-midnight entry, silently jumping that row's timestamp forward
    /// four hours with no trace of the earlier event. Finding 1 showed
    /// every real repeat gap in the sample was either well under a minute
    /// or well over 30 — nothing landed near this boundary, so 30 minutes
    /// costs at most a couple of extra banners across the ~6-hour sample
    /// while eliminating the multi-hour-jump failure mode. Anchoring to
    /// `firstOccurrenceAt` rather than `timestamp` matters precisely
    /// because that failure mode isn't only reachable via one big gap: a
    /// chain of small, individually-compliant gaps can walk the same
    /// distance if the anchor is allowed to slide forward on every
    /// collapse — see `firstOccurrenceAt`'s doc comment for the real-data
    /// repro (round 2 review).
    public static let collapseWindow: TimeInterval = 30 * 60

    /// Result of `recordOrCollapse`: either a brand-new entry was appended
    /// (`recorded`), or a repeat matched an existing unread entry and was
    /// folded into it in place (`collapsed`) — its `repeatCount`
    /// incremented and its `timestamp` refreshed to the repeat's own,
    /// rather than a new row appended.
    public enum RecordOutcome: Equatable, Sendable {
        case recorded(BellFeedEntry)
        case collapsed(BellFeedEntry)
    }

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

    /// #0298: records `entry` unless it is a redundant repeat of an
    /// existing still-unread entry, in which case that entry absorbs it
    /// instead of a duplicate row being appended.
    ///
    /// Matching rule (the user's settled decision, see `issues/0298.md`):
    /// same `tabID` (never global — two unrelated Sessions can share
    /// identical text, e.g. two Claude Code panes both "waiting for your
    /// input"), identical `message` including `nil == nil` for bare BEL
    /// (deliberate: a bare bell carries no information beyond "it rang
    /// again," and collapsing a BEL flood is this issue's motivating case),
    /// the candidate still unseen, and within `collapseWindow` of the
    /// candidate's **`firstOccurrenceAt`** — deliberately not its current
    /// `timestamp`. Matching against `timestamp` lets the window slide
    /// forward on every collapse, so a chain of individually-compliant
    /// gaps can walk the row's displayed time arbitrarily far from the
    /// event that actually opened it; see `firstOccurrenceAt`'s doc
    /// comment for the real-data repro that round 2 review caught. Anchor
    /// fixed, `timestamp` still refreshed: the bound is measured from
    /// where the chain started, but the row still surfaces the latest
    /// occurrence. `entry.tabID == BellFeedEntry.systemID` (the #0290
    /// footprint warning) always skips collapse outright — never matches,
    /// never used as a match candidate — since a same-`tabID` rule would
    /// otherwise wrongly fold distinct footprint steps together.
    ///
    /// On a match, the existing entry is removed from its current position,
    /// `repeatCount` incremented, `timestamp` set to `entry.timestamp`
    /// (`firstOccurrenceAt` untouched), and reinserted at index 0 —
    /// "collapse it to the latest one" means the feed row moves to the top
    /// with a refreshed time, not that it stays put. `seen`, `id`, and
    /// `summary` are left untouched: the point is this is still the *same*
    /// unread thing, just rung again.
    ///
    /// Deliberately never attempts to match against `entry` itself being
    /// seen-at-creation (i.e. call this only when the incoming occurrence
    /// is not effectively seen) — a bell arriving while its tab is
    /// currently focused is a distinct "seen" event, and in practice any
    /// earlier unread entry for that tab would already have been cleared by
    /// `WindowRuntime.markActiveTabSeen` the moment focus moved there.
    @discardableResult
    public func recordOrCollapse(_ entry: BellFeedEntry, collapseWindow: TimeInterval = collapseWindow) -> RecordOutcome {
        guard entry.tabID != BellFeedEntry.systemID else {
            return .recorded(record(entry))
        }
        guard let matchIndex = entries.firstIndex(where: { candidate in
            !candidate.seen
                && candidate.tabID == entry.tabID
                && candidate.message == entry.message
                && abs(entry.timestamp.timeIntervalSince(candidate.firstOccurrenceAt)) <= collapseWindow
        }) else {
            return .recorded(record(entry))
        }
        var collapsed = entries.remove(at: matchIndex)
        collapsed.repeatCount += 1
        collapsed.timestamp = entry.timestamp
        entries.insert(collapsed, at: 0)
        return .collapsed(collapsed)
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

    /// Updates the AI summary for the entry with the given id. A no-op when
    /// the entry is not found or when `summary` is nil (preserves the existing
    /// value). This is the only sanctioned write path for async summarization.
    public func updateSummary(_ summary: String, forEntryID id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].summary = summary
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

    @discardableResult
    public func removeEntries(matchingTabIDs tabIDs: Set<UUID>) -> [BellFeedEntry] {
        guard !tabIDs.isEmpty else { return [] }
        let removed = entries.filter { tabIDs.contains($0.tabID) }
        entries.removeAll { tabIDs.contains($0.tabID) }
        return removed
    }
}
