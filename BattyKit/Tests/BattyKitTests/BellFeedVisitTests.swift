// BellFeedVisitTests.swift

import Foundation
import Observation
import Testing
@testable import BattyKit

private nonisolated final class VisitChangeFlag: @unchecked Sendable {
    var fired = false
}

private let noContent: @MainActor (PaneContentKind) -> (any PaneContentLifecycle)? = { _ in nil }

/// A visit to a Tab removes its Bell Feed rows; focus that lands on a Tab as
/// a fallback only marks them seen (#0556).
@MainActor
struct BellFeedVisitTests {
    private struct Fixture {
        let store: AppStateStore
        let window: WindowRuntime
        let home: SessionRuntime
        let target: SessionRuntime
        let paneA: PaneRuntime
        let paneB: PaneRuntime
        let a1: UUID
        let a2: UUID
        let b1: UUID

        var messages: Set<String> {
            Set(store.bellFeed.entries.filter { $0.tabID != BellFeedEntry.systemID }.compactMap(\.message))
        }

        var footprintRowPresent: Bool {
            store.bellFeed.entries.contains { $0.tabID == BellFeedEntry.systemID }
        }

        func entries(for tabID: UUID) -> [BellFeedEntry] {
            store.bellFeed.entries.filter { $0.tabID == tabID }
        }

        /// Select `target` the way a fallback does: a direct write (whose
        /// `didSet` marks seen), then the passive `markActiveTabSeen()` again
        /// after the focus move.
        func selectTargetByFallback(focusing pane: PaneRuntime? = nil) {
            window.selectedSessionID = target.id
            if let pane { target.tree.focusedPaneID = pane.id }
            window.markActiveTabSeen()
        }
    }

    private func makeFixture() throws -> Fixture {
        let store = AppStateStore()
        store.isBattyActiveProvider = { false }
        let window = store.windows[0]
        let home = store.sessions[0]
        let target = try #require(store.addSession(title: "Target"))
        let paneA = target.tree.allPanes[0]
        let a1 = paneA.activeTabID
        let a2 = paneA.addTab().id
        paneA.activeTabID = a1
        let paneBID = try #require(store.splitPane(id: paneA.id, direction: .horizontal))
        let paneB = try #require(target.tree.allPanes.first { $0.id == paneBID })
        let b1 = paneB.activeTabID
        target.tree.focusedPaneID = paneB.id
        window.selectedSessionID = home.id

        store.recordCLINotification(tabID: a1, title: "a1", body: nil, playSound: false)
        store.recordCLINotification(tabID: a2, title: "a2", body: nil, playSound: false)
        store.recordCLINotification(tabID: b1, title: "b1", body: nil, playSound: false)
        store.recordCLINotification(tabID: b1, title: "b1 read", body: nil, playSound: false)
        let read = try #require(store.bellFeed.entries.first { $0.message == "b1 read" })
        store.markBellSeen(id: read.id)
        store.recordFootprintWarning(footprintBytes: 5_000_000_000, step: 1)

        let fixture = Fixture(store: store, window: window, home: home, target: target,
                              paneA: paneA, paneB: paneB, a1: a1, a2: a2, b1: b1)
        #expect(fixture.messages == ["a1", "a2", "b1", "b1 read"], "precondition")
        #expect(fixture.footprintRowPresent, "precondition")
        #expect(target.unseenBellCount == 3, "precondition")
        return fixture
    }

    private func setSideBySideFrames(_ f: Fixture) {
        f.target.paneFrames.frames = [
            f.paneA.id: CGRect(x: 0, y: 0, width: 100, height: 100),
            f.paneB.id: CGRect(x: 100, y: 0, width: 100, height: 100),
        ]
    }

    // MARK: - Visits

    @Test func sidebarSelectionRemovesTheFocusedTabsRowsOnly() throws {
        let f = try makeFixture()
        f.window.selectSessionFromSidebar(id: f.target.id)
        #expect(f.messages == ["a1", "a2"])
        #expect(f.footprintRowPresent)
        #expect(f.target.unseenBellCount == 2)
        #expect(f.paneA.unseenBellCount == 2)
        #expect(f.paneB.unseenBellCount == 0)
    }

    @Test func sidebarReassertingTheSelectedSessionRemovesNothing() throws {
        let f = try makeFixture()
        f.selectTargetByFallback()
        f.window.selectSessionFromSidebar(id: f.target.id)
        #expect(f.messages == ["a1", "a2", "b1", "b1 read"])
        #expect(f.entries(for: f.b1).allSatisfy { $0.seen })
        #expect(f.target.unseenBellCount == 2)
    }

    @Test func sidebarPaneRowRemovesThatPanesActiveTabRows() throws {
        let f = try makeFixture()
        f.window.activatePaneFromSidebar(sessionID: f.target.id, paneID: f.paneA.id)
        #expect(f.messages == ["a2", "b1", "b1 read"])
        #expect(f.footprintRowPresent)
        #expect(f.target.unseenBellCount == 2)
        #expect(f.paneA.unseenBellCount == 1)
        #expect(f.paneB.unseenBellCount == 1)
    }

    @Test func cmdNumberSessionSwitchRemovesTheFocusedTabsRows() throws {
        let f = try makeFixture()
        f.window.selectSession(at: 1)
        #expect(f.window.selectedSessionID == f.target.id)
        #expect(f.messages == ["a1", "a2"])
        #expect(f.target.unseenBellCount == 2)
    }

    @Test func terminalClickRemovesTheClickedTabsRows() throws {
        let f = try makeFixture()
        f.selectTargetByFallback()
        f.store.focusPane(containingTabID: f.a1)
        #expect(f.target.tree.focusedPaneID == f.paneA.id)
        #expect(f.messages == ["a2", "b1", "b1 read"])
        #expect(f.footprintRowPresent)
        #expect(f.paneA.unseenBellCount == 1)
    }

    @Test func terminalClickOnATabNotInViewRemovesNothing() throws {
        let f = try makeFixture()
        f.store.focusPane(containingTabID: f.a2)
        #expect(f.messages == ["a1", "a2", "b1", "b1 read"])
        #expect(f.target.unseenBellCount == 3)
    }

    @Test func tabChipClickRemovesTheChosenTabsRowsOnly() throws {
        let f = try makeFixture()
        f.selectTargetByFallback()
        f.paneA.activeTabID = f.a2
        f.store.focusPane(id: f.paneA.id)
        #expect(f.messages == ["a1", "b1", "b1 read"])
        #expect(f.paneA.unseenBellCount == 1)
    }

    @Test func adjacentPaneFocusRemovesTheNewPanesActiveTabRows() throws {
        let f = try makeFixture()
        f.selectTargetByFallback()
        setSideBySideFrames(f)
        f.window.focusPane(adjacent: .left)
        #expect(f.target.tree.focusedPaneID == f.paneA.id)
        #expect(f.messages == ["a2", "b1", "b1 read"])
    }

    @Test func adjacentPaneFocusWithNoNeighbourRemovesNothing() throws {
        let f = try makeFixture()
        f.selectTargetByFallback()
        setSideBySideFrames(f)
        f.window.focusPane(adjacent: .right)
        #expect(f.target.tree.focusedPaneID == f.paneB.id)
        #expect(f.messages == ["a1", "a2", "b1", "b1 read"])
    }

    @Test func selectTabAtIndexInFocusedPaneRemovesThatTabsRows() throws {
        let f = try makeFixture()
        f.selectTargetByFallback(focusing: f.paneA)
        f.window.selectTabInFocusedPane(at: 1)
        #expect(f.paneA.activeTabID == f.a2)
        #expect(f.messages == ["a1", "b1", "b1 read"])
        #expect(f.paneA.unseenBellCount == 0)
    }

    @Test func selectNextTabInFocusedPaneRemovesThatTabsRows() throws {
        let f = try makeFixture()
        f.selectTargetByFallback(focusing: f.paneA)
        f.window.selectNextTabInFocusedPane()
        #expect(f.paneA.activeTabID == f.a2)
        #expect(f.messages == ["a1", "b1", "b1 read"])
        #expect(f.entries(for: f.a1).allSatisfy { $0.seen })
    }

    @Test func selectPreviousTabInFocusedPaneRemovesThatTabsRows() throws {
        let f = try makeFixture()
        f.selectTargetByFallback(focusing: f.paneA)
        f.window.selectPreviousTabInFocusedPane()
        #expect(f.paneA.activeTabID == f.a2)
        #expect(f.messages == ["a1", "b1", "b1 read"])
    }

    @Test func openQuicklyJumpRemovesTheTabsRows() throws {
        let f = try makeFixture()
        f.window.jumpToTab(sessionID: f.target.id, tabID: f.a2)
        #expect(f.messages == ["a1", "b1", "b1 read"])
        #expect(f.footprintRowPresent)
        #expect(f.target.unseenBellCount == 2)
    }

    @Test func feedRowJumpRemovesEveryRowOfThatTabAndKeepsTheRest() throws {
        let f = try makeFixture()
        f.store.recordCLINotification(tabID: f.a1, title: "a1 again", body: nil, playSound: false)
        #expect(f.entries(for: f.a1).count == 2, "precondition")
        let entry = try #require(f.store.bellFeed.entries.first { $0.message == "a1 again" })
        f.store.markBellSeen(id: entry.id)
        f.store.jumpToBellEntry(entry)
        #expect(f.entries(for: f.a1).isEmpty)
        #expect(f.messages == ["a2", "b1", "b1 read"])
        #expect(f.footprintRowPresent)
        #expect(f.target.unseenBellCount == 2)
    }

    @Test func notificationTapOnADeadWindowEntryMarksSeenAndRemovesNothing() throws {
        let f = try makeFixture()
        let original = try #require(f.store.bellFeed.entries.first { $0.message == "a1" })
        var dead = original
        dead.windowID = UUID()
        f.store.jumpToBellEntry(dead)
        #expect(f.store.bellFeed.entries.first { $0.id == original.id }?.seen == true)
        #expect(f.messages == ["a1", "a2", "b1", "b1 read"])
        #expect(f.window.selectedSessionID == f.home.id)
    }

    @Test func cliSessionFocusRemovesTheFocusedTabsRows() throws {
        let f = try makeFixture()
        f.store.focusSessionForXPC(id: f.target.id)
        #expect(f.messages == ["a1", "a2"])
        #expect(f.target.unseenBellCount == 2)
    }

    @Test func cliPaneFocusRemovesThatPanesActiveTabRows() throws {
        let f = try makeFixture()
        f.store.focusPaneForXPC(id: f.paneA.id)
        #expect(f.messages == ["a2", "b1", "b1 read"])
        #expect(f.paneB.unseenBellCount == 1)
    }

    @Test func cliTabFocusRemovesThatTabsRowsOnly() throws {
        let f = try makeFixture()
        f.store.focusTabForXPC(id: f.a2)
        #expect(f.messages == ["a1", "b1", "b1 read"])
        #expect(f.paneA.unseenBellCount == 1)
    }

    @Test func openingAnAlreadyOpenProjectRemovesItsFocusedTabsRows() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("batty-visit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("root")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = AppStateStore(
            nameCache: SessionNameCache(fileURL: base.appendingPathComponent("cache.json")),
            projectsFileURL: base.appendingPathComponent("projects.json")
        )
        store.isBattyActiveProvider = { false }
        let home = store.sessions[0]
        let project = Project(name: "Visit", rootPath: root.path, color: .violet, layout: .preset(.singlePane))
        try store.projectStore.upsert(project)
        let session = try store.openProject(id: project.id, mode: .openNew, contentFactory: noContent).session
        let tabID = try #require(session.focusedTerminalPane?.activeTabID)
        store.windows[0].selectedSessionID = home.id
        store.recordCLINotification(tabID: tabID, title: "project row", body: nil, playSound: false)
        store.recordCLINotification(tabID: home.tree.allPanes[0].activeTabID, title: "home row", body: nil, playSound: false)
        #expect(store.bellFeed.entries.count == 2, "precondition")

        let result = try store.openProject(id: project.id, mode: .focusExistingOrOpen, contentFactory: noContent)

        #expect(!result.wasCreated)
        #expect(store.bellFeed.entries.map(\.message) == ["home row"])
        #expect(session.unseenBellCount == 0)
    }

    @Test func aVisitWithNothingToRemoveDoesNotWriteTheFeed() throws {
        let f = try makeFixture()
        let homeTab = f.home.tree.allPanes[0].activeTabID
        #expect(f.entries(for: homeTab).isEmpty, "precondition")
        let changed = VisitChangeFlag()
        withObservationTracking { _ = f.store.bellFeed.entries } onChange: { changed.fired = true }
        f.store.focusPane(containingTabID: homeTab)
        #expect(!changed.fired)
        #expect(f.messages == ["a1", "a2", "b1", "b1 read"])
    }

    // MARK: - Not visits

    @Test func selectionFallbackAfterClosingTheSelectedSessionMarksSeenAndKeepsRows() throws {
        let f = try makeFixture()
        f.store.removeSession(id: f.home.id)
        #expect(f.window.selectedSessionID == f.target.id, "precondition: the fallback selected target")
        f.window.markActiveTabSeen()
        #expect(f.messages == ["a1", "a2", "b1", "b1 read"])
        #expect(f.entries(for: f.b1).allSatisfy { $0.seen })
        #expect(f.target.unseenBellCount == 2)
    }

    @Test func focusFallbackAfterClosingAPaneMarksSeenAndKeepsRows() throws {
        let f = try makeFixture()
        f.selectTargetByFallback()
        f.store.closePane(id: f.paneB.id)
        #expect(f.target.tree.focusedPaneID == f.paneA.id, "precondition: focus fell back to paneA")
        f.window.markActiveTabSeen()
        #expect(f.messages == ["a1", "a2"])
        #expect(f.entries(for: f.a1).allSatisfy { $0.seen })
        #expect(f.paneA.unseenBellCount == 1)
    }

    @Test func activeTabFallbackAfterClosingATabMarksSeenAndKeepsRows() throws {
        let f = try makeFixture()
        f.paneA.activeTabID = f.a2
        f.selectTargetByFallback(focusing: f.paneA)
        f.store.closeTab(id: f.a2)
        #expect(f.paneA.activeTabID == f.a1, "precondition: a1 became active")
        f.window.markActiveTabSeen()
        #expect(f.messages == ["a1", "b1", "b1 read"])
        #expect(f.entries(for: f.a1).allSatisfy { $0.seen })
    }

    @Test func addingATabOrSplittingRemovesNothing() throws {
        let f = try makeFixture()
        f.selectTargetByFallback(focusing: f.paneA)
        let before = f.messages
        _ = f.store.addTab(toPaneID: f.paneA.id)
        f.window.markActiveTabSeen()
        _ = f.store.splitPane(id: f.paneA.id, direction: .vertical)
        f.window.markActiveTabSeen()
        #expect(f.messages == before)
        #expect(before.contains("a1"))
    }

    @Test func markAllBellsSeenKeepsEveryRow() throws {
        let f = try makeFixture()
        f.store.markAllBellsSeen()
        #expect(f.messages == ["a1", "a2", "b1", "b1 read"])
        #expect(f.footprintRowPresent)
        #expect(f.store.bellFeed.entries.allSatisfy { $0.seen })
    }

    @Test func clearReadBellsLeavesUnreadCountersAlone() throws {
        let f = try makeFixture()
        func counters() -> [Int] {
            let tabs = f.paneA.tabs + f.paneB.tabs
            return [f.target.unseenBellCount, f.paneA.unseenBellCount, f.paneB.unseenBellCount,
                    f.store.bellFeed.unseenCount] + tabs.map(\.unseenBellCount)
        }
        let before = counters()

        f.store.clearReadBells()

        #expect(f.messages == ["a1", "a2", "b1"])
        #expect(f.footprintRowPresent, "the footprint row is unread")
        #expect(counters() == before)

        let footprint = try #require(f.store.bellFeed.entries.first { $0.tabID == BellFeedEntry.systemID })
        f.store.markBellSeen(id: footprint.id)
        let afterMark = counters()
        f.store.clearReadBells()
        #expect(!f.footprintRowPresent)
        #expect(f.messages == ["a1", "a2", "b1"])
        #expect(counters() == afterMark)
        #expect(f.store.bellFeed.readCount == 0)
    }

    @Test func clearReadBellsLeavesTheDecisionHistoryUntouched() throws {
        let f = try makeFixture()
        let before = f.store.bellDecisionHistory.records
        #expect(!before.isEmpty, "precondition")
        f.store.markAllBellsSeen()
        f.store.clearReadBells()
        #expect(f.messages.isEmpty)
        #expect(f.store.bellDecisionHistory.records == before)
    }

    @Test func aFootprintRowSurvivesVisitsAndItsOwnClick() throws {
        let f = try makeFixture()
        f.window.selectSessionFromSidebar(id: f.target.id)
        f.window.selectSessionFromSidebar(id: f.home.id)
        f.store.focusPane(containingTabID: f.home.tree.allPanes[0].activeTabID)
        let footprint = try #require(f.store.bellFeed.entries.first { $0.tabID == BellFeedEntry.systemID })
        #expect(!footprint.seen, "precondition: visits left the footprint row untouched")
        f.store.jumpToBellEntry(footprint)
        let after = try #require(f.store.bellFeed.entries.first { $0.id == footprint.id })
        #expect(after.seen)
        #expect(f.window.selectedSessionID == f.home.id)
    }

    @Test func aVisitLeavesTheDecisionHistoryUntouched() throws {
        let f = try makeFixture()
        let before = f.store.bellDecisionHistory.records
        #expect(!before.isEmpty, "precondition")
        f.window.selectSessionFromSidebar(id: f.target.id)
        f.store.focusPane(containingTabID: f.a1)
        f.window.selectNextTabInFocusedPane()
        f.store.focusTabForXPC(id: f.b1)
        #expect(f.messages.isEmpty)
        #expect(f.store.bellDecisionHistory.records == before)
    }

    // MARK: - Fired Reminders (#0514, #0639)

    /// A fired Reminder on `target`, as one fired while `paneB` was focused,
    /// plus one on `home`; focus then moves to `paneA`.
    private func addFiredReminders(_ f: Fixture) -> (target: UUID, home: UUID) {
        func fired(_ session: SessionRuntime) -> FiredReminder {
            let now = Date()
            return FiredReminder(id: UUID(), sessionID: session.id, windowID: f.window.id.value,
                                 note: "Reminder", createdAt: now, dueAt: now, firedAt: now)
        }
        let onTarget = fired(f.target)
        let onHome = fired(f.home)
        f.store.firedReminders.record(onTarget)
        f.store.firedReminders.record(onHome)
        f.target.tree.focusedPaneID = f.paneA.id
        return (onTarget.id, onHome.id)
    }

    @Test func visitingASessionRemovesItsFiredReminder() throws {
        let f = try makeFixture()
        let ids = addFiredReminders(f)
        f.window.selectSessionFromSidebar(id: f.target.id)
        let remaining = Set(f.store.firedReminders.items.map(\.id))
        #expect(!remaining.contains(ids.target))
        #expect(remaining.contains(ids.home), "another Session's Reminder stays")
        let bells = Set(f.store.bellFeed.entries.filter { $0.tabID != BellFeedEntry.systemID }.compactMap(\.message))
        #expect(bells == ["a2", "b1", "b1 read"], "the inactive Tab's and the other Pane's bell rows stay")
        #expect(f.footprintRowPresent)
    }

    @Test func aFallbackSelectionMarksTheFiredReminderRead() throws {
        let f = try makeFixture()
        let ids = addFiredReminders(f)
        f.window.selectedSessionID = f.target.id
        f.window.markActiveTabSeen()
        let item = try #require(f.store.firedReminders.items.first { $0.id == ids.target })
        #expect(item.seen)
        let home = try #require(f.store.firedReminders.items.first { $0.id == ids.home })
        #expect(!home.seen)
    }

    @Test func clearReadBellsLeavesFiredRemindersAlone() throws {
        let f = try makeFixture()
        let ids = addFiredReminders(f)
        _ = f.store.firedReminders.markSeen(id: ids.home)

        f.store.clearReadBells()

        #expect(Set(f.store.firedReminders.items.map(\.id)) == [ids.target, ids.home], "a read fired Reminder is not a read bell")
        #expect(!f.store.bellFeed.entries.contains { $0.message == "b1 read" })
    }
}
