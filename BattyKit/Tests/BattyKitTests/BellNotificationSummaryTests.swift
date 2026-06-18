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

    @Test func resolvedTreatsAbsentKeyAsTrue() {
        UserDefaults.standard.removeObject(forKey: SettingsPreference.summarizeNotificationsWithAIKey)
        defer { UserDefaults.standard.removeObject(forKey: SettingsPreference.summarizeNotificationsWithAIKey) }
        #expect(SettingsPreference.resolvedSummarizeNotificationsWithAI() == true)
    }

    @Test func resolvedRespectsExplicitFalse() {
        UserDefaults.standard.set(false, forKey: SettingsPreference.summarizeNotificationsWithAIKey)
        defer { UserDefaults.standard.removeObject(forKey: SettingsPreference.summarizeNotificationsWithAIKey) }
        #expect(SettingsPreference.resolvedSummarizeNotificationsWithAI() == false)
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
struct AppStateStoreSummarizationTests {

    private func makeStore(summarizer: NotificationSummarizing?) -> AppStateStore {
        let store = AppStateStore()
        store.notificationSummarizer = summarizer
        return store
    }

    private func awaitSummaryTask(_ store: AppStateStore, entryID: UUID) async {
        // Give async tasks a chance to settle on the main actor.
        await Task.yield()
        await Task.yield()
    }

    @Test func summarizationSkippedWhenSummarizerIsNil() {
        let store = makeStore(summarizer: nil)
        let session = store.sessions[0]
        let tab = session.tree.allPanes[0].tabs[0]
        store.selectedSessionID = nil

        tab.terminal.terminalDidRequestDesktopNotification(title: "CI", body: "passed")
        store.recordDesktopNotification(forTabID: tab.id)

        #expect(store.bellFeed.entries.first?.summary == nil)
    }

    @Test func summarizationSkippedWhenToggleOff() async {
        let summarizer = RecordingSummarizer(result: "build passed")
        let store = makeStore(summarizer: summarizer)
        store.selectedSessionID = nil

        UserDefaults.standard.set(false, forKey: SettingsPreference.summarizeNotificationsWithAIKey)
        defer { UserDefaults.standard.removeObject(forKey: SettingsPreference.summarizeNotificationsWithAIKey) }

        let session = store.sessions[0]
        let tab = session.tree.allPanes[0].tabs[0]
        tab.terminal.terminalDidRequestDesktopNotification(title: "CI", body: "passed")
        store.recordDesktopNotification(forTabID: tab.id)

        await Task.yield()
        await Task.yield()

        #expect(summarizer.calls.isEmpty)
        #expect(store.bellFeed.entries.first?.summary == nil)
    }

    @Test func summarizationRunsWhenToggleOn() async {
        let summarizer = RecordingSummarizer(result: "tests passed")
        let store = makeStore(summarizer: summarizer)
        store.selectedSessionID = nil

        UserDefaults.standard.set(true, forKey: SettingsPreference.summarizeNotificationsWithAIKey)
        defer { UserDefaults.standard.removeObject(forKey: SettingsPreference.summarizeNotificationsWithAIKey) }

        let session = store.sessions[0]
        let tab = session.tree.allPanes[0].tabs[0]
        tab.terminal.terminalDidRequestDesktopNotification(title: "CI", body: "passed")
        store.recordDesktopNotification(forTabID: tab.id)
        let entryID = store.bellFeed.entries.first!.id

        // Wait for the async summarization task to complete.
        for _ in 0..<10 {
            await Task.yield()
            if store.bellFeed.entries.first?.summary != nil { break }
        }

        #expect(summarizer.calls.count == 1)
        #expect(store.bellFeed.entries.first?.summary == "tests passed")
        let call = summarizer.calls[0]
        #expect(call.message?.contains("CI") == true || call.message?.contains("passed") == true)
        _ = entryID
    }

    @Test func nilSummaryFromSummarizerLeavesEntryUnchanged() async {
        let summarizer = RecordingSummarizer(result: nil)
        let store = makeStore(summarizer: summarizer)
        store.selectedSessionID = nil

        UserDefaults.standard.set(true, forKey: SettingsPreference.summarizeNotificationsWithAIKey)
        defer { UserDefaults.standard.removeObject(forKey: SettingsPreference.summarizeNotificationsWithAIKey) }

        let session = store.sessions[0]
        let tab = session.tree.allPanes[0].tabs[0]
        tab.terminal.terminalDidRequestDesktopNotification(title: "Bell", body: "")
        store.recordDesktopNotification(forTabID: tab.id)

        for _ in 0..<10 {
            await Task.yield()
            if !summarizer.calls.isEmpty { break }
        }

        #expect(store.bellFeed.entries.first?.summary == nil)
    }

    @Test func junkSummaryFromSummarizerIsDropped() async {
        let junk = String(repeating: "x", count: NotificationSummary.maxLength + 1)
        let summarizer = RecordingSummarizer(result: junk)
        let store = makeStore(summarizer: summarizer)
        store.selectedSessionID = nil

        UserDefaults.standard.set(true, forKey: SettingsPreference.summarizeNotificationsWithAIKey)
        defer { UserDefaults.standard.removeObject(forKey: SettingsPreference.summarizeNotificationsWithAIKey) }

        let session = store.sessions[0]
        let tab = session.tree.allPanes[0].tabs[0]
        tab.terminal.terminalDidRequestDesktopNotification(title: "Junk", body: "response")
        store.recordDesktopNotification(forTabID: tab.id)

        for _ in 0..<10 {
            await Task.yield()
            if !summarizer.calls.isEmpty { break }
        }

        #expect(store.bellFeed.entries.first?.summary == nil)
    }

    @Test func summaryUpdatesCorrectEntry() async {
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
        let store = AppStateStore()
        store.notificationSummarizer = summarizer
        store.selectedSessionID = nil

        UserDefaults.standard.set(true, forKey: SettingsPreference.summarizeNotificationsWithAIKey)
        defer { UserDefaults.standard.removeObject(forKey: SettingsPreference.summarizeNotificationsWithAIKey) }

        let session = store.sessions[0]
        let pane = session.tree.allPanes[0]
        pane.addTab()
        let tab0 = pane.tabs[0]
        let tab1 = pane.tabs[1]

        tab0.terminal.terminalDidRequestDesktopNotification(title: "CI", body: "ci-passed")
        store.recordDesktopNotification(forTabID: tab0.id)
        let firstEntryID = store.bellFeed.entries.first!.id

        tab1.terminal.terminalDidRequestDesktopNotification(title: "Tests", body: "tests-failed")
        store.recordDesktopNotification(forTabID: tab1.id)

        for _ in 0..<30 {
            await Task.yield()
            if store.bellFeed.entries.count >= 2,
               store.bellFeed.entries.allSatisfy({ $0.summary != nil }) { break }
        }

        let entry0 = store.bellFeed.entries.first(where: { $0.id == firstEntryID })
        let entry1 = store.bellFeed.entries.first(where: { $0.id != firstEntryID })
        #expect(entry0?.summary == "ci passed")
        #expect(entry1?.summary == "tests failed")
    }

    @Test func bellTickSummarizationAlsoRuns() async {
        let summarizer = RecordingSummarizer(result: "bell rang")
        let store = makeStore(summarizer: summarizer)
        store.selectedSessionID = nil

        UserDefaults.standard.set(true, forKey: SettingsPreference.summarizeNotificationsWithAIKey)
        defer { UserDefaults.standard.removeObject(forKey: SettingsPreference.summarizeNotificationsWithAIKey) }

        let session = store.sessions[0]
        let tab = session.tree.allPanes[0].tabs[0]
        tab.terminal.terminalDidRingBell()
        store.recordBellTick(forTabID: tab.id)

        for _ in 0..<10 {
            await Task.yield()
            if store.bellFeed.entries.first?.summary != nil { break }
        }

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
