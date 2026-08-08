// BellFeedCollapseTests.swift

import Foundation
import Testing
@testable import BattyKit

/// #0298: the collapse rule itself, exercised directly against
/// `BellFeedStore.recordOrCollapse` with fabricated timestamps so the
/// 30-minute boundary can be tested precisely without depending on real
/// wall-clock time. The user's settled decision (`issues/0298.md`):
///
/// - Match key is `tabID` + exact `message` equality (including
///   `nil == nil` for bare BEL) -- never `tabLabel` (Claude Code's
///   animated spinner glyph means the same message can carry different
///   tab-title digests across repeats).
/// - The candidate must still be unseen.
/// - The repeat must land within `BellFeedStore.collapseWindow` (30
///   minutes) of the candidate's `firstOccurrenceAt` -- a fixed anchor set
///   once when the entry is first created, not its repeatedly-refreshed
///   `timestamp` (round 2 review: a sliding anchor lets a chain of
///   individually-compliant gaps drift arbitrarily far from the event that
///   opened the row -- see `threeEventsAtZeroTwentyFiveAndFiftyMinutes_
///   yieldsTwoRowsUnderFixedAnchor` below).
/// - System entries (`BellFeedEntry.systemID`) never participate.
///
/// End-to-end wiring through `AppStateStore` (notification suppression,
/// the #0297 decision record's `outcome=suppressed:collapsedIntoUnread`,
/// and unseen-counter consistency) is covered separately in
/// `AppStateStoreBellCollapseTests` below.
@MainActor
struct BellFeedCollapseTests {

    private func makeEntry(
        tabID: UUID,
        message: String? = nil,
        seen: Bool = false,
        timestamp: Date
    ) -> BellFeedEntry {
        BellFeedEntry(
            timestamp: timestamp,
            windowID: UUID(),
            sessionID: UUID(),
            paneID: UUID(),
            tabID: tabID,
            surfaceID: UUID(),
            message: message,
            seen: seen
        )
    }

    private static let base = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Core matching rule

    @Test func identicalMessageSameTabUnread_collapses() {
        let store = BellFeedStore()
        let tabID = UUID()
        let first = makeEntry(tabID: tabID, message: "Claude is waiting for your input", timestamp: Self.base)
        store.record(first)

        let repeat1 = makeEntry(tabID: tabID, message: "Claude is waiting for your input", timestamp: Self.base.addingTimeInterval(60))
        let outcome = store.recordOrCollapse(repeat1)

        #expect(store.entries.count == 1)
        #expect(store.entries[0].repeatCount == 2)
        #expect(store.entries[0].timestamp == Self.base.addingTimeInterval(60))
        #expect(store.entries[0].id == first.id, "collapsing must reuse the original entry's identity, not mint a new one")
        if case .collapsed(let merged) = outcome {
            #expect(merged.id == first.id)
        } else {
            Issue.record("expected .collapsed, got \(outcome)")
        }
    }

    @Test func identicalMessageDifferentTab_doesNotCollapse() {
        // #0298 finding 3: the same digest appeared in two unrelated
        // Sessions in the real export ("Pi Trouble" and "Batty") -- a
        // text-only rule would have wrongly merged them.
        let store = BellFeedStore()
        let tabA = UUID()
        let tabB = UUID()
        store.record(makeEntry(tabID: tabA, message: "Claude is waiting for your input", timestamp: Self.base))

        let outcome = store.recordOrCollapse(makeEntry(tabID: tabB, message: "Claude is waiting for your input", timestamp: Self.base.addingTimeInterval(60)))

        #expect(store.entries.count == 2)
        if case .recorded = outcome {} else {
            Issue.record("expected .recorded, got \(outcome)")
        }
    }

    @Test func differentMessageSameTab_doesNotCollapse() {
        let store = BellFeedStore()
        let tabID = UUID()
        store.record(makeEntry(tabID: tabID, message: "Claude is waiting for your input", timestamp: Self.base))

        let outcome = store.recordOrCollapse(makeEntry(tabID: tabID, message: "build failed", timestamp: Self.base.addingTimeInterval(60)))

        #expect(store.entries.count == 2)
        if case .recorded = outcome {} else {
            Issue.record("expected .recorded, got \(outcome)")
        }
    }

    @Test func repeatAfterEntryMarkedSeen_doesNotCollapse() {
        let store = BellFeedStore()
        let tabID = UUID()
        let first = makeEntry(tabID: tabID, message: "build failed", timestamp: Self.base)
        store.record(first)
        store.markSeen(id: first.id)

        let outcome = store.recordOrCollapse(makeEntry(tabID: tabID, message: "build failed", timestamp: Self.base.addingTimeInterval(60)))

        #expect(store.entries.count == 2)
        #expect(store.entries.contains { $0.repeatCount != 1 } == false, "neither entry should show a repeat count")
        if case .recorded = outcome {} else {
            Issue.record("expected .recorded, got \(outcome)")
        }
    }

    // MARK: - 30-minute time bound, both directions

    @Test func repeatAt29Minutes_collapses() {
        let store = BellFeedStore()
        let tabID = UUID()
        store.record(makeEntry(tabID: tabID, message: "build failed", timestamp: Self.base))

        let outcome = store.recordOrCollapse(makeEntry(tabID: tabID, message: "build failed", timestamp: Self.base.addingTimeInterval(29 * 60)))

        #expect(store.entries.count == 1)
        if case .collapsed = outcome {} else {
            Issue.record("expected .collapsed at 29 minutes, got \(outcome)")
        }
    }

    @Test func repeatAt31Minutes_doesNotCollapse() {
        let store = BellFeedStore()
        let tabID = UUID()
        store.record(makeEntry(tabID: tabID, message: "build failed", timestamp: Self.base))

        let outcome = store.recordOrCollapse(makeEntry(tabID: tabID, message: "build failed", timestamp: Self.base.addingTimeInterval(31 * 60)))

        #expect(store.entries.count == 2)
        if case .recorded = outcome {} else {
            Issue.record("expected .recorded at 31 minutes, got \(outcome)")
        }
    }

    @Test func repeatExactlyAt30Minutes_collapsesInclusive() {
        let store = BellFeedStore()
        let tabID = UUID()
        store.record(makeEntry(tabID: tabID, message: "build failed", timestamp: Self.base))

        let outcome = store.recordOrCollapse(makeEntry(tabID: tabID, message: "build failed", timestamp: Self.base.addingTimeInterval(30 * 60)))

        if case .collapsed = outcome {} else {
            Issue.record("expected .collapsed at exactly the 30-minute bound (inclusive), got \(outcome)")
        }
    }

    /// Round-2 review: every boundary test above uses a two-event chain,
    /// where anchoring the 30-minute bound to the candidate's fixed
    /// `firstOccurrenceAt` vs. its repeatedly-refreshed `timestamp` is
    /// indistinguishable (both equal the same single prior occurrence).
    /// A three-event chain is the minimum that tells them apart: 0 -> 25
    /// collapses either way (25 min from either anchor), but 25 -> 50 is
    /// 50 minutes from the fixed first-occurrence anchor (over the bound)
    /// while only 25 minutes from the just-refreshed timestamp (under it).
    /// Fixed-anchor must produce two rows; a sliding anchor would wrongly
    /// produce one row at repeatCount 3 -- the real bug the reviewer traced
    /// to `8E75F975`'s 05:58:46 -> 06:20:00 -> 06:23:32 -> 06:44:38 chain
    /// (every consecutive gap under 30 minutes, but 45m52s end to end).
    @Test func threeEventsAtZeroTwentyFiveAndFiftyMinutes_yieldsTwoRowsUnderFixedAnchor() {
        let store = BellFeedStore()
        let tabID = UUID()
        store.record(makeEntry(tabID: tabID, message: "build failed", timestamp: Self.base))

        let secondOutcome = store.recordOrCollapse(makeEntry(tabID: tabID, message: "build failed", timestamp: Self.base.addingTimeInterval(25 * 60)))
        if case .collapsed = secondOutcome {} else {
            Issue.record("expected the 25-minute repeat to collapse, got \(secondOutcome)")
        }
        #expect(store.entries.count == 1)
        #expect(store.entries[0].repeatCount == 2)
        #expect(store.entries[0].firstOccurrenceAt == Self.base, "the anchor must stay pinned to the first occurrence after a collapse")

        let thirdOutcome = store.recordOrCollapse(makeEntry(tabID: tabID, message: "build failed", timestamp: Self.base.addingTimeInterval(50 * 60)))

        #expect(store.entries.count == 2, "50 minutes from the fixed first-occurrence anchor is over the 30-minute bound -- this must be a new row, not a x3 collapse")
        if case .recorded = thirdOutcome {} else {
            Issue.record("expected .recorded (a sliding anchor would wrongly collapse this: 50 - 25 = 25 minutes, under the bound), got \(thirdOutcome)")
        }
    }

    // MARK: - Bare BEL (message: nil) sub-rule -- #0298 finding 7: real-data-untested, needs its own coverage

    @Test func twoBareBellsSameTab_collapse() {
        let store = BellFeedStore()
        let tabID = UUID()
        store.record(makeEntry(tabID: tabID, message: nil, timestamp: Self.base))

        let outcome = store.recordOrCollapse(makeEntry(tabID: tabID, message: nil, timestamp: Self.base.addingTimeInterval(1)))

        #expect(store.entries.count == 1)
        #expect(store.entries[0].repeatCount == 2)
        if case .collapsed = outcome {} else {
            Issue.record("expected .collapsed, got \(outcome)")
        }
    }

    @Test func bareBellsFromDifferentTabs_doNotCollapse() {
        let store = BellFeedStore()
        let tabA = UUID()
        let tabB = UUID()
        store.record(makeEntry(tabID: tabA, message: nil, timestamp: Self.base))

        let outcome = store.recordOrCollapse(makeEntry(tabID: tabB, message: nil, timestamp: Self.base.addingTimeInterval(1)))

        #expect(store.entries.count == 2)
        if case .recorded = outcome {} else {
            Issue.record("expected .recorded, got \(outcome)")
        }
    }

    // MARK: - Flood scenario: many rapid repeats end up as one entry with the right count

    @Test func twentyRapidBareBellsCollapseToOneEntryWithRepeatCount20() {
        // The motivating case from the issue: `for i in {1..20}; do printf
        // '\a'; done` must not produce 20 feed rows.
        let store = BellFeedStore()
        let tabID = UUID()
        for i in 0..<20 {
            store.recordOrCollapse(makeEntry(tabID: tabID, message: nil, timestamp: Self.base.addingTimeInterval(Double(i))))
        }
        #expect(store.entries.count == 1)
        #expect(store.entries[0].repeatCount == 20)
    }

    // MARK: - System entries never collapse

    @Test func systemEntries_neverCollapse() {
        let store = BellFeedStore()
        let first = BellFeedEntry(
            timestamp: Self.base,
            windowID: BellFeedEntry.systemID,
            sessionID: BellFeedEntry.systemID,
            paneID: BellFeedEntry.systemID,
            tabID: BellFeedEntry.systemID,
            surfaceID: BellFeedEntry.systemID,
            message: "Memory footprint warning",
            seen: false
        )
        store.record(first)

        let second = BellFeedEntry(
            timestamp: Self.base.addingTimeInterval(1),
            windowID: BellFeedEntry.systemID,
            sessionID: BellFeedEntry.systemID,
            paneID: BellFeedEntry.systemID,
            tabID: BellFeedEntry.systemID,
            surfaceID: BellFeedEntry.systemID,
            message: "Memory footprint warning",
            seen: false
        )
        let outcome = store.recordOrCollapse(second)

        #expect(store.entries.count == 2, "system entries (#0290) must skip collapse outright, even with identical text")
        if case .recorded = outcome {} else {
            Issue.record("expected .recorded for a system entry, got \(outcome)")
        }
    }
}
