// BellNotificationSummaryTests.swift

import Foundation
import Testing
@testable import BattyKit

// MARK: - Test double

private final class RecordingSummarizer: NotificationSummarizing {
    var result: String?
    private(set) var calls: [(message: String?, tabTitle: String?, sessionTitle: String?)] = []

    init(result: String?) {
        self.result = result
    }

    func summarize(message: String?, tabTitle: String?, sessionTitle: String?) async -> String? {
        calls.append((message: message, tabTitle: tabTitle, sessionTitle: sessionTitle))
        return result
    }
}

// MARK: - NotificationSummary sanitizer

struct NotificationSummaryTests {

    @Test func sanitizeAcceptsShortCleanPhrases() {
        #expect(NotificationSummary.sanitize("build failed: 3 errors") == "build failed: 3 errors")
        #expect(NotificationSummary.sanitize("tests passed") == "tests passed")
        #expect(NotificationSummary.sanitize("  npm install finished  ") == "npm install finished")
        #expect(NotificationSummary.sanitize("\"deploy succeeded\"") == "deploy succeeded")
    }

    @Test func sanitizeRejectsNoneAndEmpty() {
        #expect(NotificationSummary.sanitize("NONE") == nil)
        #expect(NotificationSummary.sanitize("none") == nil)
        #expect(NotificationSummary.sanitize("") == nil)
        #expect(NotificationSummary.sanitize("   ") == nil)
    }

    @Test func sanitizeRejectsTooLongStrings() {
        let long = String(repeating: "a", count: NotificationSummary.maxLength + 1)
        #expect(NotificationSummary.sanitize(long) == nil)
    }

    @Test func sanitizeAcceptsAtMaxLength() {
        let exact = String(repeating: "a", count: NotificationSummary.maxLength)
        #expect(NotificationSummary.sanitize(exact) == exact)
    }

    @Test func sanitizeRejectsControlCharacters() {
        #expect(NotificationSummary.sanitize("line\nbreak") == nil)
        #expect(NotificationSummary.sanitize("tab\there") == nil)
        #expect(NotificationSummary.sanitize("bell\u{07}char") == nil)
    }

    @Test func sanitizeStripsWrappingQuotes() {
        #expect(NotificationSummary.sanitize("\u{201C}smart quoted\u{201D}") == "smart quoted")
        #expect(NotificationSummary.sanitize("'single quoted'") == "single quoted")
        #expect(NotificationSummary.sanitize("`backtick`") == "backtick")
    }
}

// MARK: - Settings default

struct SummarizeNotificationsSettingsTests {

    @Test func defaultIsTrue() {
        #expect(SettingsPreference.defaultSummarizeNotificationsWithAI == true)
    }
}

// MARK: - BellFeedEntry Codable round-trip

struct BellFeedEntryCodableTests {

    private func makeEntry(summary: String? = nil) -> BellFeedEntry {
        BellFeedEntry(
            timestamp: Date(timeIntervalSince1970: 1_000_000),
            windowID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            sessionID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            paneID: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
            tabID: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!,
            surfaceID: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!,
            message: "build finished",
            summary: summary
        )
    }

    @Test func roundTripWithSummaryPreservesSummary() throws {
        let entry = makeEntry(summary: "build failed: 3 errors")
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(BellFeedEntry.self, from: data)
        #expect(decoded.summary == "build failed: 3 errors")
        #expect(decoded.message == "build finished")
    }

    @Test func roundTripWithNilSummaryDecodesNil() throws {
        let entry = makeEntry(summary: nil)
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(BellFeedEntry.self, from: data)
        #expect(decoded.summary == nil)
    }

    @Test func oldDataWithoutSummaryDecodesSuccessfully() throws {
        // Simulate persisted data from before #0246 — no `summary` key.
        let json = """
        {
            "id": "00000000-0000-0000-0000-000000000010",
            "timestamp": 1000000.0,
            "windowID": "00000000-0000-0000-0000-000000000001",
            "sessionID": "00000000-0000-0000-0000-000000000002",
            "paneID": "00000000-0000-0000-0000-000000000003",
            "tabID": "00000000-0000-0000-0000-000000000004",
            "surfaceID": "00000000-0000-0000-0000-000000000005",
            "message": "old bell",
            "seen": false
        }
        """
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(BellFeedEntry.self, from: data)
        #expect(decoded.summary == nil)
        #expect(decoded.message == "old bell")
    }
}

// MARK: - Summarization wiring in AppStateStore

@MainActor
final class AppStateStoreSummarizationTests {
    /// A `UserDefaults` suite private to one test invocation, isolated from
    /// `.standard` — every concurrent `./build.sh unit` run on the machine
    /// shares `.standard` through one `cfprefsd` (#0426).
    private let testDefaults = TestDefaults()

    @MainActor deinit { testDefaults.tearDown() }

    private func makeStore(summarizer: NotificationSummarizing?) -> AppStateStore {
        let store = AppStateStore(preferences: testDefaults.defaults)
        store.notificationSummarizer = summarizer
        return store
    }

    /// Outcome of `awaitSummarizationTask(_:bound:)` — kept distinct from a
    /// plain `Bool` because "the `Task` was never scheduled" (checked
    /// synchronously via `AppStateStore.summarizationTaskForTesting`, see
    /// the skip tests below) and "the `Task` was scheduled but never
    /// completed" are different failures with different causes; conflating
    /// them into one `false` hides which one actually happened.
    private enum SummarizationAwaitResult: Equatable {
        case completed
        case timedOut
    }

    /// Awaits `task`'s completion, bounded by `bound` as a hang-guard only
    /// (`docs/async-test-seams.md` §4): a genuine regression where the
    /// `Task` never completes reports `.timedOut` instead of hanging the
    /// suite. Same `ResumeOnce` + timeout-race shape as
    /// `ChildProcessReadiness.waitForReadableData` (`ChildProcessReadiness.swift`)
    /// — kept in the test target rather than production source, since it's
    /// pure test bookkeeping with no reason to live alongside the type it
    /// tests.
    ///
    /// `nonisolated` deliberately: `AppStateStoreSummarizationTests` is
    /// `@MainActor`, and a `DispatchWorkItem` closure formed inside a
    /// MainActor-isolated method infers MainActor isolation by default —
    /// but `asyncAfter` runs it on `DispatchQueue.global`, a real thread
    /// with no MainActor affinity. The mismatch is caught, and trapped, by
    /// the Swift 6 runtime's isolation check (`swift_task_checkIsolatedSwift`)
    /// the instant the timeout fires. `nonisolated` removes the inferred
    /// isolation; nothing in this body touches MainActor-isolated state.
    private nonisolated func awaitSummarizationTask(_ task: Task<Void, Never>, bound: TimeInterval = TestBounds.hangGuard) async -> SummarizationAwaitResult {
        await withCheckedContinuation { (continuation: CheckedContinuation<SummarizationAwaitResult, Never>) in
            let once = ResumeOnce(continuation)
            let timeoutWorkItem = DispatchWorkItem {
                once.resume(.timedOut)
            }
            once.setOnResumed { timeoutWorkItem.cancel() }
            Task {
                await task.value
                once.resume(.completed)
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + bound, execute: timeoutWorkItem)
        }
    }

    @Test func resolvedTreatsAbsentKeyAsTrue() {
        #expect(SettingsPreference.resolvedSummarizeNotificationsWithAI(defaults: testDefaults.defaults) == true)
    }

    @Test func resolvedRespectsExplicitFalse() {
        testDefaults.defaults.set(false, forKey: SettingsPreference.summarizeNotificationsWithAIKey)
        #expect(SettingsPreference.resolvedSummarizeNotificationsWithAI(defaults: testDefaults.defaults) == false)
    }

    @Test func summarizationSkippedWhenSummarizerIsNil() async {
        let store = makeStore(summarizer: nil)
        let session = store.sessions[0]
        let tab = session.tree.allPanes[0].tabs[0]
        store.selectedSessionID = nil

        tab.terminal.terminalDidRequestDesktopNotification(title: "CI", body: "passed")
        await awaitTerminalStatePublish { tab.terminal.lastDesktopNotificationAt != nil }
        store.recordDesktopNotification(forTabID: tab.id)

        #expect(store.bellFeed.entries.first != nil)
        #expect(store.bellFeed.entries.first?.summary == nil)
    }

    @Test func summarizationSkippedWhenToggleOff() async {
        let summarizer = RecordingSummarizer(result: "build passed")
        let store = makeStore(summarizer: summarizer)
        store.selectedSessionID = nil

        let session = store.sessions[0]
        let tab = session.tree.allPanes[0].tabs[0]
        tab.terminal.terminalDidRequestDesktopNotification(title: "CI", body: "passed")
        await awaitTerminalStatePublish { tab.terminal.lastDesktopNotificationAt != nil }

        store.preferences.set(false, forKey: SettingsPreference.summarizeNotificationsWithAIKey)
        store.recordDesktopNotification(forTabID: tab.id)
        let entryID = store.bellFeed.entries.first!.id

        // "Skipped" is a synchronous fact — scheduleSummarization returned
        // before ever creating a Task — not something to await.
        #expect(store.summarizationTaskForTesting(entryID: entryID) == nil,
                "toggle off must skip scheduling a summarization Task entirely")

        #expect(store.bellFeed.entries.first != nil)
    }

    @Test func summarizationRunsWhenToggleOn() async throws {
        let summarizer = RecordingSummarizer(result: "tests passed")
        let store = makeStore(summarizer: summarizer)
        store.selectedSessionID = nil

        let session = store.sessions[0]
        let tab = session.tree.allPanes[0].tabs[0]
        tab.terminal.terminalDidRequestDesktopNotification(title: "CI", body: "passed")
        await awaitTerminalStatePublish { tab.terminal.lastDesktopNotificationAt != nil }

        store.preferences.set(true, forKey: SettingsPreference.summarizeNotificationsWithAIKey)
        store.recordDesktopNotification(forTabID: tab.id)
        let entryID = store.bellFeed.entries.first!.id

        let task = try #require(store.summarizationTaskForTesting(entryID: entryID),
                                 "toggle on with a summarizer must schedule a summarization Task")
        let result = await awaitSummarizationTask(task)
        #expect(result == .completed, "summarization Task did not complete within the hang-guard bound")

        #expect(summarizer.calls.count == 1)
        #expect(store.bellFeed.entries.first?.summary == "tests passed")
        let call = summarizer.calls[0]
        #expect(call.message?.contains("CI") == true || call.message?.contains("passed") == true)
    }

    @Test func nilSummaryFromSummarizerLeavesEntryUnchanged() async throws {
        let summarizer = RecordingSummarizer(result: nil)
        let store = makeStore(summarizer: summarizer)
        store.selectedSessionID = nil

        let session = store.sessions[0]
        let tab = session.tree.allPanes[0].tabs[0]
        tab.terminal.terminalDidRequestDesktopNotification(title: "Bell", body: "")
        await awaitTerminalStatePublish { tab.terminal.lastDesktopNotificationAt != nil }

        store.preferences.set(true, forKey: SettingsPreference.summarizeNotificationsWithAIKey)
        store.recordDesktopNotification(forTabID: tab.id)
        let entryID = store.bellFeed.entries.first!.id

        let task = try #require(store.summarizationTaskForTesting(entryID: entryID),
                                 "toggle on with a summarizer must schedule a summarization Task")
        let result = await awaitSummarizationTask(task)
        #expect(result == .completed, "summarization Task did not complete within the hang-guard bound")

        #expect(store.bellFeed.entries.first != nil)
        #expect(summarizer.calls.count == 1)
        #expect(store.bellFeed.entries.first?.summary == nil)
    }

    @Test func junkSummaryFromSummarizerIsDropped() async throws {
        let junk = String(repeating: "x", count: NotificationSummary.maxLength + 1)
        let summarizer = RecordingSummarizer(result: junk)
        let store = makeStore(summarizer: summarizer)
        store.selectedSessionID = nil

        let session = store.sessions[0]
        let tab = session.tree.allPanes[0].tabs[0]
        tab.terminal.terminalDidRequestDesktopNotification(title: "Junk", body: "response")
        await awaitTerminalStatePublish { tab.terminal.lastDesktopNotificationAt != nil }

        store.preferences.set(true, forKey: SettingsPreference.summarizeNotificationsWithAIKey)
        store.recordDesktopNotification(forTabID: tab.id)
        let entryID = store.bellFeed.entries.first!.id

        let task = try #require(store.summarizationTaskForTesting(entryID: entryID),
                                 "toggle on with a summarizer must schedule a summarization Task")
        let result = await awaitSummarizationTask(task)
        #expect(result == .completed, "summarization Task did not complete within the hang-guard bound")

        #expect(store.bellFeed.entries.first != nil)
        #expect(summarizer.calls.count == 1)
        #expect(store.bellFeed.entries.first?.summary == nil)
    }

    @Test func summaryUpdatesCorrectEntry() async throws {
        // Use a message-keyed summarizer so the two concurrent tasks return
        // distinct values regardless of completion order.
        final class MessageKeyedSummarizer: NotificationSummarizing {
            func summarize(message: String?, tabTitle: String?, sessionTitle: String?) async -> String? {
                guard let message else { return nil }
                if message.contains("ci-passed") { return "ci passed" }
                if message.contains("tests-failed") { return "tests failed" }
                return nil
            }
        }
        let summarizer = MessageKeyedSummarizer()
        let store = AppStateStore(preferences: testDefaults.defaults)
        store.notificationSummarizer = summarizer
        store.selectedSessionID = nil

        let session = store.sessions[0]
        let pane = session.tree.allPanes[0]
        pane.addTab()
        let tab0 = pane.tabs[0]
        let tab1 = pane.tabs[1]

        tab0.terminal.terminalDidRequestDesktopNotification(title: "CI", body: "ci-passed")
        await awaitTerminalStatePublish { tab0.terminal.lastDesktopNotificationAt != nil }

        store.preferences.set(true, forKey: SettingsPreference.summarizeNotificationsWithAIKey)
        store.recordDesktopNotification(forTabID: tab0.id)
        let firstEntryID = store.bellFeed.entries.first!.id

        tab1.terminal.terminalDidRequestDesktopNotification(title: "Tests", body: "tests-failed")
        await awaitTerminalStatePublish { tab1.terminal.lastDesktopNotificationAt != nil }
        store.recordDesktopNotification(forTabID: tab1.id)
        let secondEntryID = store.bellFeed.entries.first(where: { $0.id != firstEntryID })!.id

        let firstTask = try #require(store.summarizationTaskForTesting(entryID: firstEntryID),
                                      "toggle on with a summarizer must schedule a summarization Task per entry")
        let secondTask = try #require(store.summarizationTaskForTesting(entryID: secondEntryID),
                                       "toggle on with a summarizer must schedule a summarization Task per entry")
        // Both tasks are already running concurrently; awaiting one's
        // completion signal doesn't block the other's progress.
        let firstResult = await awaitSummarizationTask(firstTask)
        let secondResult = await awaitSummarizationTask(secondTask)
        #expect(firstResult == .completed && secondResult == .completed,
                "summarization Tasks did not complete within the hang-guard bound")

        #expect(store.bellFeed.entries.count == 2)
        let entry0 = store.bellFeed.entries.first(where: { $0.id == firstEntryID })
        let entry1 = store.bellFeed.entries.first(where: { $0.id != firstEntryID })
        #expect(entry0?.summary == "ci passed")
        #expect(entry1?.summary == "tests failed")
    }

    @Test func bellTickSummarizationAlsoRuns() async throws {
        let summarizer = RecordingSummarizer(result: "bell rang")
        let store = makeStore(summarizer: summarizer)
        store.selectedSessionID = nil

        let session = store.sessions[0]
        let tab = session.tree.allPanes[0].tabs[0]
        tab.terminal.terminalDidRingBell()
        await awaitTerminalStatePublish { tab.terminal.bellCount > 0 }

        store.preferences.set(true, forKey: SettingsPreference.summarizeNotificationsWithAIKey)
        store.recordBellTick(forTabID: tab.id)
        let entryID = store.bellFeed.entries.first!.id

        let task = try #require(store.summarizationTaskForTesting(entryID: entryID),
                                 "toggle on with a summarizer must schedule a summarization Task")
        let result = await awaitSummarizationTask(task)
        #expect(result == .completed, "summarization Task did not complete within the hang-guard bound")

        #expect(store.bellFeed.entries.first != nil)
        #expect(store.bellFeed.entries.first?.summary == "bell rang")
    }
}

// MARK: - BellFeedStore.updateSummary

@MainActor
struct BellFeedStoreUpdateSummaryTests {

    @Test func updateSummaryWritesToCorrectEntry() {
        let store = BellFeedStore()
        let entry = BellFeedEntry(
            timestamp: Date(),
            windowID: UUID(),
            sessionID: UUID(),
            paneID: UUID(),
            tabID: UUID(),
            surfaceID: UUID()
        )
        store.record(entry)
        store.updateSummary("build succeeded", forEntryID: entry.id)
        #expect(store.entries.first?.summary == "build succeeded")
    }

    @Test func updateSummaryNoopsForUnknownID() {
        let store = BellFeedStore()
        let entry = BellFeedEntry(
            timestamp: Date(),
            windowID: UUID(),
            sessionID: UUID(),
            paneID: UUID(),
            tabID: UUID(),
            surfaceID: UUID()
        )
        store.record(entry)
        store.updateSummary("should be ignored", forEntryID: UUID())
        #expect(store.entries.first?.summary == nil)
    }
}

// MARK: - FoundationModelsNotificationSummarizer prompt

struct NotificationSummarizerPromptTests {

    @Test func promptIncludesMessageAndContext() {
        let prompt = FoundationModelsNotificationSummarizer.prompt(
            message: "build failed: 3 errors",
            tabTitle: "vim",
            sessionTitle: "Batty"
        )
        #expect(prompt.contains("build failed: 3 errors"))
        #expect(prompt.contains("vim"))
        #expect(prompt.contains("Batty"))
    }

    @Test func promptWithNilsUsesPlaceholder() {
        let prompt = FoundationModelsNotificationSummarizer.prompt(
            message: nil,
            tabTitle: nil,
            sessionTitle: nil
        )
        #expect(prompt.contains("no message"))
    }

    @Test func promptOmitsEmptyTabTitle() {
        let prompt = FoundationModelsNotificationSummarizer.prompt(
            message: "done",
            tabTitle: "",
            sessionTitle: nil
        )
        #expect(!prompt.contains("Tab:"))
    }
}
