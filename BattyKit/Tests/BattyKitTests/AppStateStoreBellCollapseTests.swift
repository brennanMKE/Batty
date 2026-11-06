// AppStateStoreBellCollapseTests.swift

import Foundation
import Testing
@testable import BattyKit

/// #0298 end-to-end: `AppStateStore.recordBell` / `recordDesktopNotification`
/// / `recordCLINotification` all route new entries through
/// `BellFeedStore.recordOrCollapse` (the matching rule itself is covered in
/// isolation by `BellFeedCollapseTests`). These tests exercise the real
/// store methods to prove the two things `BellFeedCollapseTests` cannot:
/// a collapsed repeat never reaches `notifier.post` (no re-posted system
/// notification), and it still lands in the #0297 decision history with
/// `outcome=suppressed:collapsedIntoUnread` so the export never silently
/// drops a bell.
///
/// `SpyBellNotifier` is defined in `SessionMuteTests.swift` (internal to
/// this test target).
@MainActor
struct AppStateStoreBellCollapseTests {

    @Test func collapsedRepeatDoesNotRepostASystemNotification() {
        let notifier = SpyBellNotifier()
        let store = AppStateStore(notifier: notifier)
        store.isBattyActiveProvider = { false }
        let session = store.addSession(title: "Background")!
        store.selectedSessionID = store.sessions[0].id
        let tabID = session.focusedPaneAnyKind.activeTabID

        store.recordCLINotification(tabID: tabID, title: "Claude is waiting for your input", body: nil, playSound: false)
        store.recordCLINotification(tabID: tabID, title: "Claude is waiting for your input", body: nil, playSound: false)

        #expect(store.bellFeed.entries.count == 1, "the repeat must collapse into the existing unread entry, not append a second row")
        #expect(store.bellFeed.entries[0].repeatCount == 2)
        #expect(notifier.postedEntries.count == 1, "the collapsed repeat must not re-post a system notification")
    }

    @Test func collapsedRepeatIsRecordedWithTheCollapsedIntoUnreadOutcome() {
        let notifier = SpyBellNotifier()
        let store = AppStateStore(notifier: notifier)
        store.isBattyActiveProvider = { false }
        let session = store.addSession(title: "Background")!
        store.selectedSessionID = store.sessions[0].id
        let tabID = session.focusedPaneAnyKind.activeTabID

        store.recordCLINotification(tabID: tabID, title: "build failed", body: nil, playSound: false)
        store.recordCLINotification(tabID: tabID, title: "build failed", body: nil, playSound: false)

        #expect(store.bellDecisionHistory.records.count == 2, "the #0297 log must still show two decisions -- the collapse must not vanish from the history")
        #expect(store.bellDecisionHistory.records[0].outcome == .submitted)
        #expect(store.bellDecisionHistory.records[1].outcome == .suppressed(.collapsedIntoUnread))
    }

    @Test func nonRedundantRepeatsBothSubmit() {
        let notifier = SpyBellNotifier()
        let store = AppStateStore(notifier: notifier)
        store.isBattyActiveProvider = { false }
        let session = store.addSession(title: "Background")!
        store.selectedSessionID = store.sessions[0].id
        let tabID = session.focusedPaneAnyKind.activeTabID

        store.recordCLINotification(tabID: tabID, title: "build failed", body: nil, playSound: false)
        store.recordCLINotification(tabID: tabID, title: "tests passed", body: nil, playSound: false)

        #expect(store.bellFeed.entries.count == 2)
        #expect(notifier.postedEntries.count == 2)
        #expect(store.bellDecisionHistory.records.map(\.outcome) == [.submitted, .submitted])
    }

    /// #0298's stated design goal: counters and entries stay consistent by
    /// construction. A collapsed entry represents `repeatCount` raw bell
    /// occurrences; `WindowRuntime.decrementUnseen` must release all of
    /// them when the one row that absorbed them is marked seen via the
    /// feed-click / notification-tap path (`AppStateStore.markBellSeen`),
    /// not just the tab-visit path (`markActiveTabSeen`, which already had
    /// its own residual-reset safety net before this issue).
    @Test func markBellSeenOnACollapsedEntryDecrementsByTheFullRepeatCount() async {
        let notifier = SpyBellNotifier()
        let store = AppStateStore(notifier: notifier)
        store.isBattyActiveProvider = { false }
        let focused = store.sessions[0]
        let background = store.addSession(title: "Background")!
        store.selectedSessionID = focused.id

        let pane = background.tree.allPanes[0]
        let tab = pane.tabs[0]
        store.ringBell(in: tab)
        store.ringBell(in: tab)
        store.ringBell(in: tab)

        #expect(store.bellFeed.entries.count == 1)
        #expect(store.bellFeed.entries[0].repeatCount == 3)
        #expect(tab.unseenBellCount == 3)
        #expect(pane.unseenBellCount == 3)
        #expect(background.unseenBellCount == 3)

        store.markBellSeen(id: store.bellFeed.entries[0].id)

        #expect(tab.unseenBellCount == 0)
        #expect(pane.unseenBellCount == 0)
        #expect(background.unseenBellCount == 0)
    }

    /// `recordBell` loops `for _ in 0..<count` when several BEL ticks
    /// arrive batched in one call (bells rung before the Tab's intake was
    /// wired are flushed as one event).
    /// Each iteration must see the entry the previous iteration just
    /// recorded/collapsed as a live candidate.
    @Test func batchedBellTicksInOneCallCollapseTogether() async {
        let notifier = SpyBellNotifier()
        let store = AppStateStore(notifier: notifier)
        store.isBattyActiveProvider = { false }
        let session = store.addSession(title: "Background")!
        store.selectedSessionID = store.sessions[0].id
        let tab = session.focusedPaneAnyKind.activeTab!

        for _ in 0..<3 { tab.terminalDelegate.terminalDidRingBell() }
        store.wireBellReporting(for: tab)

        #expect(store.bellFeed.entries.count == 1)
        #expect(store.bellFeed.entries[0].repeatCount == 3)
        #expect(notifier.postedEntries.count == 1)
    }
}
