// CloseOtherTabsBellCleanupTests.swift

import Foundation
import Testing
@testable import BattyKit

/// Close Other Tabs removes the closed Tabs' Bell Feed rows and unseen
/// counts, as `closeTab` does (#0559).
@MainActor
struct CloseOtherTabsBellCleanupTests {
    private struct Fixture {
        let store: AppStateStore
        let window: WindowRuntime
        let target: SessionRuntime
        let paneA: PaneRuntime
        let v1: UUID
        let v2: UUID
        let kept: UUID
        let b1: UUID
        let reminderID: UUID
        let decisionCount: Int

        var bellMessages: Set<String> {
            Set(store.bellFeed.entries
                .filter { $0.kind == .bell && $0.tabID != BellFeedEntry.systemID }
                .compactMap(\.message))
        }

        var footprintRowPresent: Bool {
            store.bellFeed.entries.contains { $0.tabID == BellFeedEntry.systemID }
        }

        var reminderRowPresent: Bool {
            store.bellFeed.entries.contains { $0.id == reminderID }
        }

        var keptTab: TabRuntime? { paneA.tabs.first { $0.id == kept } }

        func expectUntouched() {
            #expect(bellMessages == ["v1", "v1 read", "v2", "kept", "b1"])
            #expect(paneA.tabs.map(\.id) == [v1, v2, kept])
            #expect(paneA.unseenBellCount == 3)
            #expect(target.unseenBellCount == 4)
            #expect(keptTab?.unseenBellCount == 1)
            #expect(reminderRowPresent)
            #expect(footprintRowPresent)
        }

        func expectClosed() {
            #expect(bellMessages == ["kept", "b1"])
            #expect(paneA.tabs.map(\.id) == [kept])
            #expect(paneA.unseenBellCount == 1)
            #expect(target.unseenBellCount == 2)
            #expect(keptTab?.unseenBellCount == 1)
            #expect(store.pendingCloseRequest == nil)
        }
    }

    private func makeFixture() throws -> Fixture {
        let store = AppStateStore()
        store.isBattyActiveProvider = { false }
        let window = store.windows[0]
        let home = store.sessions[0]
        let target = try #require(store.addSession(title: "Target"))
        let paneA = target.tree.allPanes[0]
        let v1 = paneA.activeTabID
        let v2 = paneA.addTab().id
        let kept = paneA.addTab().id
        paneA.activeTabID = v1
        let paneBID = try #require(store.splitPane(id: paneA.id, direction: .horizontal))
        let paneB = try #require(target.tree.allPanes.first { $0.id == paneBID })
        let b1 = paneB.activeTabID
        window.selectedSessionID = home.id

        store.recordCLINotification(tabID: v1, title: "v1", body: nil, playSound: false)
        store.recordCLINotification(tabID: v1, title: "v1 read", body: nil, playSound: false)
        let read = try #require(store.bellFeed.entries.first { $0.message == "v1 read" })
        store.markBellSeen(id: read.id)
        store.recordCLINotification(tabID: v2, title: "v2", body: nil, playSound: false)
        store.recordCLINotification(tabID: kept, title: "kept", body: nil, playSound: false)
        store.recordCLINotification(tabID: b1, title: "b1", body: nil, playSound: false)
        let reminder = BellFeedEntry(timestamp: Date(), windowID: window.id.value, sessionID: target.id,
                                     paneID: paneA.id, tabID: v1, surfaceID: UUID(),
                                     message: "Reminder", kind: .reminder)
        store.bellFeed.entries.insert(reminder, at: 0)
        store.recordFootprintWarning(footprintBytes: 5_000_000_000, step: 1)

        let f = Fixture(store: store, window: window, target: target, paneA: paneA,
                        v1: v1, v2: v2, kept: kept, b1: b1, reminderID: reminder.id,
                        decisionCount: store.bellDecisionHistory.records.count)
        #expect(paneA.activeTabID == v1, "precondition: kept Tab is not active")
        f.expectUntouched()
        return f
    }

    @Test func closeOtherTabsRemovesTheClosedTabsRowsAndDecrementsCounters() throws {
        let f = try makeFixture()
        f.store.requestCloseOtherTabs(paneID: f.paneA.id, keepingTabID: f.kept)
        f.expectClosed()
    }

    @Test func closeOtherTabsKeepsReminderAndFootprintRows() throws {
        let f = try makeFixture()
        f.store.requestCloseOtherTabs(paneID: f.paneA.id, keepingTabID: f.kept)
        #expect(f.reminderRowPresent)
        #expect(f.footprintRowPresent)
    }

    @Test func closeOtherTabsLeavesBellDecisionHistoryUntouched() throws {
        let f = try makeFixture()
        f.store.requestCloseOtherTabs(paneID: f.paneA.id, keepingTabID: f.kept)
        #expect(f.store.bellDecisionHistory.records.count == f.decisionCount)
    }

    @Test func confirmedCloseOtherTabsWithABusyVictimRemovesTheClosedTabsRows() throws {
        let f = try makeFixture()
        try #require(f.paneA.tabs.first { $0.id == f.v2 }).needsConfirmCloseOverride = true
        f.store.requestCloseOtherTabs(paneID: f.paneA.id, keepingTabID: f.kept)
        guard case .otherTabs = f.store.pendingCloseRequest?.kind else {
            Issue.record("expected an .otherTabs confirmation")
            return
        }
        f.expectUntouched()
        f.window.confirmPendingClose()
        f.expectClosed()
    }

    @Test func cancelledCloseOtherTabsLeavesTheFeedUntouched() throws {
        let f = try makeFixture()
        try #require(f.paneA.tabs.first { $0.id == f.v2 }).needsConfirmCloseOverride = true
        f.store.requestCloseOtherTabs(paneID: f.paneA.id, keepingTabID: f.kept)
        f.window.cancelPendingClose()
        #expect(f.store.pendingCloseRequest == nil)
        f.expectUntouched()
    }

    @Test func closeOtherTabsWithAnUnknownKeptTabChangesNothing() throws {
        let f = try makeFixture()
        f.store.requestCloseOtherTabs(paneID: f.paneA.id, keepingTabID: UUID())
        f.expectUntouched()
    }
}
