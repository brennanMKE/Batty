// BellFeedSeenDropTests.swift

import Foundation
import Testing
@testable import BattyKit

private final class StubSummarizer: NotificationSummarizing {
    func summarize(message: String?, tabTitle: String?, sessionTitle: String?) async -> NotificationSummarizationResult {
        NotificationSummarizationResult(instructions: "stub", prompt: "stub", rawReply: "summary")
    }
}

@MainActor
final class BellFeedSeenDropTests {
    private let testDefaults = TestDefaults()

    @MainActor deinit { testDefaults.tearDown() }

    private func makeStore(notifier: BellNotifying? = nil, active: Bool) -> AppStateStore {
        let store = AppStateStore(notifier: notifier, preferences: testDefaults.defaults)
        store.isBattyActiveProvider = { active }
        return store
    }

    private func focusedTab(_ store: AppStateStore) -> TabRuntime {
        store.sessions[0].focusedPaneAnyKind.activeTab!
    }

    @Test func belFromTheFocusedTabWhileActiveAddsNoEntry() async {
        let store = makeStore(active: true)
        let tab = focusedTab(store)
        let pane = store.sessions[0].focusedPaneAnyKind

        store.ringBell(in: tab)

        #expect(store.bellFeed.entries.isEmpty)
        #expect(tab.bellCount == 1)
        #expect(tab.unseenBellCount == 0)
        #expect(pane.unseenBellCount == 0)
        #expect(store.sessions[0].unseenBellCount == 0)

        store.isBattyActiveProvider = { false }
        store.ringBell(in: tab)

        #expect(tab.bellCount == 2, "the dropped bell must still count on the Tab")
        #expect(store.bellFeed.entries.count == 1)
        #expect(store.bellFeed.entries.first?.seen == true)
    }

    @Test func oscFromTheFocusedTabWhileActiveAddsNoEntry() async {
        let store = makeStore(active: true)
        let tab = focusedTab(store)

        store.requestDesktopNotification(in: tab, title: "first", body: "one")
        #expect(store.bellFeed.entries.isEmpty)

        store.isBattyActiveProvider = { false }
        store.requestDesktopNotification(in: tab, title: "second", body: "two")

        #expect(store.bellFeed.entries.count == 1)
        #expect(store.bellFeed.entries.first?.message?.contains("second") == true)
    }

    @Test func cliNotifyToTheFocusedTabWhileActiveAddsNoEntryAndStillReportsPosted() {
        let store = makeStore(active: true)
        let tabID = focusedTab(store).id

        #expect(store.recordCLINotification(tabID: tabID, title: "Done", body: nil, playSound: false) == .posted)
        #expect(store.bellFeed.entries.isEmpty)

        store.isBattyActiveProvider = { false }
        #expect(store.recordCLINotification(tabID: tabID, title: "Done", body: nil, playSound: false) == .posted)
        #expect(store.bellFeed.entries.count == 1)
        #expect(store.bellFeed.entries.first?.seen == true)
    }

    @Test func focusedTabWhileBattyIsInactiveKeepsASeenEntry() {
        let store = makeStore(active: false)
        let tab = focusedTab(store)

        store.recordCLINotification(tabID: tab.id, title: "Done", body: nil, playSound: false)

        #expect(store.bellFeed.entries.count == 1)
        #expect(store.bellFeed.entries.first?.seen == true)
        #expect(tab.unseenBellCount == 0)
        #expect(store.sessions[0].unseenBellCount == 0)
    }

    @Test func nonFocusedTabWhileActiveKeepsAnUnseenEntry() {
        let store = makeStore(active: true)
        let second = store.addSession(title: "Other")!
        store.selectedSessionID = store.sessions[0].id

        store.recordCLINotification(tabID: second.focusedPaneAnyKind.activeTabID, title: "Other done", body: nil, playSound: false)
        #expect(store.bellFeed.entries.count == 1)
        #expect(store.bellFeed.entries.first?.seen == false)
        #expect(second.unseenBellCount == 1)

        store.recordCLINotification(tabID: focusedTab(store).id, title: "Focused done", body: nil, playSound: false)
        #expect(store.bellFeed.entries.count == 1)
        #expect(second.unseenBellCount == 1)
    }

    @Test func droppedBellStillRecordsAFrontmostAndSeenDecisionAndNeverReachesTheNotifier() throws {
        testDefaults.defaults.set(true, forKey: SettingsPreference.systemNotificationsKey)
        let notifier = SpyBellNotifier()
        let store = makeStore(notifier: notifier, active: true)
        let tabID = focusedTab(store).id

        store.recordCLINotification(tabID: tabID, title: "Done", body: nil, playSound: false)

        let decision = try #require(store.bellDecisionHistory.records.last)
        #expect(decision.outcome == .suppressed(.frontmostAndSeen))
        #expect(decision.battyActive == true)
        #expect(decision.entrySeenAtCreation == true)
        #expect(!store.bellFeed.entries.contains { $0.id == decision.entryID })
        #expect(notifier.postedEntries.isEmpty)

        store.isBattyActiveProvider = { false }
        store.recordCLINotification(tabID: tabID, title: "Done", body: nil, playSound: false)
        #expect(store.bellDecisionHistory.records.last?.outcome == .submitted)
        #expect(notifier.postedEntries.count == 1)
    }

    @Test func notificationsOffWhileActiveStillDropsTheRow() {
        testDefaults.defaults.set(false, forKey: SettingsPreference.systemNotificationsKey)
        let store = makeStore(notifier: SpyBellNotifier(), active: true)

        store.recordCLINotification(tabID: focusedTab(store).id, title: "Done", body: nil, playSound: false)

        #expect(store.bellDecisionHistory.records.last?.outcome == .suppressed(.systemNotificationsDisabled))
        #expect(store.bellFeed.entries.isEmpty)
    }

    @Test func mutedFocusedTabWhileActiveDropsTheRow() {
        let store = makeStore(notifier: SpyBellNotifier(), active: true)
        store.sessions[0].notificationsMuted = true

        store.recordCLINotification(tabID: focusedTab(store).id, title: "Done", body: nil, playSound: false)

        #expect(store.bellDecisionHistory.records.last?.outcome == .suppressed(.sessionMuted))
        #expect(store.bellFeed.entries.isEmpty)
    }

    @Test func isBattyActiveIsReadOncePerBellAndTheDecisionAgrees() async {
        let store = makeStore(active: false)
        var calls = 0
        store.isBattyActiveProvider = {
            calls += 1
            return calls % 2 == 1
        }
        let tab = focusedTab(store)

        store.ringBell(in: tab, times: 2)

        #expect(calls == 2)
        #expect(store.bellFeed.entries.count == 1)
        #expect(store.bellDecisionHistory.records.map(\.battyActive) == [true, false])

        store.recordCLINotification(tabID: tab.id, title: "Done", body: nil, playSound: false)
        #expect(calls == 3)
    }

    @Test func summarizationIsNotScheduledForADroppedEntry() async throws {
        testDefaults.defaults.set(true, forKey: SettingsPreference.summarizeNotificationsWithAIKey)
        let store = makeStore(active: true)
        store.notificationSummarizer = StubSummarizer()
        let second = store.addSession(title: "Other")!
        store.selectedSessionID = store.sessions[0].id

        store.recordCLINotification(tabID: focusedTab(store).id, title: "Focused", body: nil, playSound: false)
        let dropped = try #require(store.bellDecisionHistory.records.last)
        #expect(store.summarizationTaskForTesting(entryID: dropped.entryID) == nil)

        store.recordCLINotification(tabID: second.focusedPaneAnyKind.activeTabID, title: "Other", body: nil, playSound: false)
        let kept = try #require(store.bellFeed.entries.first)
        let task = try #require(store.summarizationTaskForTesting(entryID: kept.id))
        #expect(await awaitBounded { await task.value })
    }
}
