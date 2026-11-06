// BellFeedRatingTests.swift

import Foundation
import Testing
@testable import BattyKit

private func ratingDecoder() -> JSONDecoder {
    let d = JSONDecoder()
    d.dateDecodingStrategy = .iso8601
    return d
}

private final class RatingStubSummarizer: NotificationSummarizing {
    let result: NotificationSummarizationResult
    init(_ result: NotificationSummarizationResult) { self.result = result }
    func summarize(message: String?, tabTitle: String?, sessionTitle: String?) async -> NotificationSummarizationResult { result }
}

struct BellCaptureRatingEncodingTests {
    @Test func ratingRoundTripsOnOneLineWithSchemaAndExplicitNulls() throws {
        let rating = BellCaptureRating(
            entryID: UUID(),
            ratedAt: Date(timeIntervalSince1970: 1_700_000_000),
            kind: .verdict,
            verdict: .good,
            suggestedText: nil,
            shownText: "line one\nline two",
            summaryAtRating: nil,
            messageAtRating: "raw"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(rating)
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(!text.contains("\n"))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["schema"] as? Int == BellCaptureSchema.version)
        #expect(object["type"] as? String == "rating")
        #expect(object["kind"] as? String == "verdict")
        #expect(object["verdict"] as? String == "good")
        #expect(object["suggestedText"] is NSNull)
        #expect(object["summaryAtRating"] is NSNull)
        #expect(try ratingDecoder().decode(BellCaptureRating.self, from: data) == rating)
    }
}

@MainActor
final class BellFeedRatingTests {
    private let testDefaults = TestDefaults()
    private let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("batty-rating-tests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)

    @MainActor deinit {
        testDefaults.tearDown()
        try? FileManager.default.removeItem(at: directory)
    }

    private struct Fixture {
        let store: AppStateStore
        let writer: BellCaptureWriter
        let tabID: UUID
    }

    private func makeFixture(capture: Bool = true, summarizer: NotificationSummarizing? = nil) -> Fixture {
        testDefaults.defaults.set(capture, forKey: SettingsPreference.captureBellFeedDataKey)
        let store = AppStateStore(notifier: SpyBellNotifier(), preferences: testDefaults.defaults)
        store.isBattyActiveProvider = { false }
        store.notificationSummarizer = summarizer
        let writer = BellCaptureWriter(directory: directory)
        store.bellCaptureWriter = writer
        let session = store.addSession(title: "Background")!
        store.selectedSessionID = store.sessions[0].id
        return Fixture(store: store, writer: writer, tabID: session.focusedPaneAnyKind.activeTabID)
    }

    private func ratings(_ f: Fixture) async throws -> [BellCaptureRating] {
        let writer = f.writer
        #expect(await awaitBounded { await writer.flush() })
        guard let data = FileManager.default.contents(atPath: writer.currentFileURL.path),
              let text = String(data: data, encoding: .utf8) else { return [] }
        return try text.split(separator: "\n", omittingEmptySubsequences: true)
            .filter { $0.contains("\"type\":\"rating\"") }
            .map { try ratingDecoder().decode(BellCaptureRating.self, from: Data($0.utf8)) }
    }

    private func notify(_ f: Fixture, _ title: String = "Build", _ body: String? = "failed") throws -> BellFeedEntry {
        f.store.recordCLINotification(tabID: f.tabID, title: title, body: body, playSound: false)
        return try #require(f.store.bellFeed.entries.first)
    }

    @Test func verdictsAppendRecordsAndLatestWins() async throws {
        let f = makeFixture()
        let entry = try notify(f)
        #expect(f.store.bellRatingAvailability(for: entry) == .available)

        #expect(f.store.rateBellEntry(id: entry.id, verdict: .good))
        #expect(f.store.bellFeed.ratingVerdicts[entry.id] == .good)
        #expect(f.store.rateBellEntry(id: entry.id, verdict: .bad))
        #expect(f.store.bellFeed.ratingVerdicts[entry.id] == .bad)

        let records = try await ratings(f)
        #expect(records.map(\.verdict) == [.good, .bad])
        #expect(records.allSatisfy { $0.entryID == entry.id && $0.kind == .verdict && $0.suggestedText == nil })
        #expect(Set(records.map(\.recordID)).count == 2)
        #expect(records[0].shownText == "Build\nfailed")
    }

    @Test func ratingNeverMarksTheEntrySeen() throws {
        let f = makeFixture()
        let entry = try notify(f)
        #expect(entry.seen == false)
        f.store.rateBellEntry(id: entry.id, verdict: .good)
        f.store.rateBellEntry(id: entry.id, verdict: .cleared)
        f.store.suggestBellText(id: entry.id, text: "better")
        #expect(f.store.bellFeed.entries.first { $0.id == entry.id }?.seen == false)
        #expect(f.store.bellFeed.unseenCount == 1)
    }

    @Test func suggestionUsesTheSnapshotTakenWhenTheEditorOpened() async throws {
        let summarizer = RatingStubSummarizer(.init(prompt: "p", rawReply: "Tests passed"))
        let f = makeFixture(summarizer: summarizer)
        let entry = try notify(f, "CI", "all green")
        let snapshot = try #require(f.store.bellRatingSnapshot(forEntryID: entry.id))
        let task = try #require(f.store.summarizationTaskForTesting(entryID: entry.id))
        #expect(await awaitBounded { await task.value }, "summarization Task did not complete")
        #expect(f.store.bellFeed.entries.first { $0.id == entry.id }?.displayText == "Tests passed")

        f.store.suggestBellText(id: entry.id, text: "better", snapshot: snapshot)
        let record = try #require(try await ratings(f).first)
        #expect(record.shownText == "CI\nall green")
        #expect(record.summaryAtRating == nil)
    }

    @Test func repickingTheCurrentVerdictAppendsNothing() async throws {
        let f = makeFixture()
        let entry = try notify(f)
        #expect(f.store.rateBellEntry(id: entry.id, verdict: .good))
        #expect(f.store.rateBellEntry(id: entry.id, verdict: .good) == false)
        #expect(f.store.rateBellEntry(id: entry.id, verdict: .cleared))
        #expect(f.store.bellFeed.ratingVerdicts[entry.id] == nil)
        #expect(f.store.rateBellEntry(id: entry.id, verdict: .cleared) == false)
        let records = try await ratings(f)
        #expect(records.map(\.verdict) == [.good, .cleared])
    }

    @Test func suggestionsAppendIndependentlyOfTheVerdict() async throws {
        let f = makeFixture()
        let entry = try notify(f)
        f.store.rateBellEntry(id: entry.id, verdict: .bad)
        #expect(f.store.suggestBellText(id: entry.id, text: "  Build failed  \n"))
        #expect(f.store.suggestBellText(id: entry.id, text: "Build failed: 3 errors"))
        #expect(f.store.suggestBellText(id: entry.id, text: "  \n ") == false)

        let records = try await ratings(f)
        #expect(records.map(\.kind) == [.verdict, .suggestion, .suggestion])
        #expect(records[1].suggestedText == "Build failed")
        #expect(records[2].suggestedText == "Build failed: 3 errors")
        #expect(records[1].verdict == nil)
        #expect(f.store.bellFeed.ratingVerdicts[entry.id] == .bad)
    }

    @Test func suggestionIsCappedAtTheMessageLimit() async throws {
        let f = makeFixture()
        let entry = try notify(f)
        let long = String(repeating: "x", count: BellCaptureSchema.maxMessageCharacters + 50)
        #expect(f.store.suggestBellText(id: entry.id, text: long))
        let record = try #require(try await ratings(f).first)
        #expect(record.suggestedText?.count == BellCaptureSchema.maxMessageCharacters)
    }

    @Test func captureOffHidesRatingsAndWritesNothing() async throws {
        let f = makeFixture(capture: false)
        let entry = try notify(f)
        #expect(f.store.bellRatingAvailability(for: entry) == .hidden)
        #expect(f.store.rateBellEntry(id: entry.id, verdict: .good) == false)
        #expect(f.store.suggestBellText(id: entry.id, text: "better") == false)
        #expect(f.store.bellFeed.ratingVerdicts.isEmpty)
        let writer = f.writer
        #expect(await awaitBounded { await writer.flush() })
        #expect(await f.writer.currentFileExists() == false)
    }

    @Test func entryWithoutAnEventRecordIsNotRatable() async throws {
        let f = makeFixture(capture: false)
        let early = try notify(f, "Early", nil)
        testDefaults.defaults.set(true, forKey: SettingsPreference.captureBellFeedDataKey)
        #expect(f.store.bellRatingAvailability(for: early) == .notCaptured)
        #expect(f.store.rateBellEntry(id: early.id, verdict: .good) == false)
        #expect(f.store.suggestBellText(id: early.id, text: "better") == false)
        #expect(try await ratings(f).isEmpty)

        let later = try notify(f, "Later", nil)
        #expect(f.store.bellRatingAvailability(for: later) == .available)
    }

    @Test func clearCaptureMakesEntriesUnratableAndDropsVerdicts() async throws {
        let f = makeFixture()
        let entry = try notify(f)
        f.store.rateBellEntry(id: entry.id, verdict: .good)
        f.store.clearBellCapture()
        #expect(f.store.bellFeed.ratingVerdicts.isEmpty)
        #expect(f.store.bellRatingAvailability(for: entry) == .notCaptured)
        #expect(f.store.rateBellEntry(id: entry.id, verdict: .bad) == false)
        #expect(try await ratings(f).isEmpty)
    }

    @Test func systemEntryIsNeverRatable() throws {
        let f = makeFixture()
        let system = BellFeedEntry(
            timestamp: Date(),
            windowID: BellFeedEntry.systemID,
            sessionID: BellFeedEntry.systemID,
            paneID: BellFeedEntry.systemID,
            tabID: BellFeedEntry.systemID,
            surfaceID: BellFeedEntry.systemID,
            message: "Footprint"
        )
        f.store.bellFeed.record(system)
        f.store.bellFeed.markCaptured(system.id)
        #expect(f.store.bellRatingAvailability(for: system) == .hidden)
        #expect(f.store.rateBellEntry(id: system.id, verdict: .good) == false)
    }

    @Test func reminderEntryIsNeverRatable() throws {
        let f = makeFixture()
        let now = Date()
        let reminder = BellFeedEntry(
            timestamp: now,
            windowID: UUID(),
            sessionID: f.store.sessions[0].id,
            paneID: UUID(),
            tabID: f.tabID,
            surfaceID: f.tabID,
            message: "Stand up",
            kind: .reminder,
            reminderSetAt: now,
            reminderDueAt: now
        )
        f.store.bellFeed.record(reminder)
        f.store.bellFeed.markCaptured(reminder.id)
        #expect(f.store.bellRatingAvailability(for: reminder) == .hidden)
        #expect(f.store.rateBellEntry(id: reminder.id, verdict: .good) == false)
        #expect(f.store.suggestBellText(id: reminder.id, text: "better") == false)
        #expect(f.store.bellRatingSnapshot(forEntryID: reminder.id) == nil)
        #expect(f.store.bellFeed.ratingVerdicts.isEmpty)
    }

    @Test func shownTextTracksSummaryOrMessageAtRatingTime() async throws {
        let summarizer = RatingStubSummarizer(.init(prompt: "p", rawReply: "Tests passed"))
        let f = makeFixture(summarizer: summarizer)
        let entry = try notify(f, "CI", "all green")
        let task = try #require(f.store.summarizationTaskForTesting(entryID: entry.id))

        // The summarization Task is main-actor isolated and cannot have
        // started yet, so this rating sees the raw message.
        f.store.rateBellEntry(id: entry.id, verdict: .bad)
        #expect(await awaitBounded { await task.value }, "summarization Task did not complete")
        f.store.rateBellEntry(id: entry.id, verdict: .good)

        let records = try await ratings(f)
        #expect(records.count == 2)
        #expect(records[0].shownText == "CI\nall green")
        #expect(records[0].summaryAtRating == nil)
        #expect(records[0].messageAtRating == "CI\nall green")
        #expect(records[1].shownText == "Tests passed")
        #expect(records[1].summaryAtRating == "Tests passed")
        #expect(records[1].messageAtRating == "CI\nall green")
    }

    @Test func ratingStateDropsWhenTheEntryLeavesTheFeed() throws {
        let f = makeFixture()
        let entry = try notify(f)
        f.store.rateBellEntry(id: entry.id, verdict: .good)
        #expect(f.store.bellFeed.capturedEntryIDs.contains(entry.id))

        f.store.bellFeed.removeEntries(matchingTabIDs: [entry.tabID])
        #expect(f.store.bellFeed.ratingVerdicts.isEmpty)
        #expect(f.store.bellFeed.capturedEntryIDs.isEmpty)
    }

    @Test func ratingStateDropsWhenTheCapEvictsTheEntry() {
        let feed = BellFeedStore()
        let first = BellFeedEntry(timestamp: Date(), windowID: UUID(), sessionID: UUID(), paneID: UUID(), tabID: UUID(), surfaceID: UUID(), message: "a")
        feed.record(first)
        feed.markCaptured(first.id)
        feed.setVerdict(.good, for: first.id)
        for _ in 0..<BellFeedStore.cap {
            feed.record(BellFeedEntry(timestamp: Date(), windowID: UUID(), sessionID: UUID(), paneID: UUID(), tabID: UUID(), surfaceID: UUID()))
        }
        #expect(!feed.entries.contains { $0.id == first.id })
        #expect(feed.ratingVerdicts.isEmpty)
        #expect(!feed.capturedEntryIDs.contains(first.id))
    }
}
