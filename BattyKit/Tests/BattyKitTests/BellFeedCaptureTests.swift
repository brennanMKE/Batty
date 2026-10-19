// BellFeedCaptureTests.swift

import Foundation
import Testing
@testable import BattyKit

private func makeTempDirectory() -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("batty-capture-tests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
}

private func readLines(_ url: URL) -> [String] {
    guard let data = FileManager.default.contents(atPath: url.path),
          let text = String(data: data, encoding: .utf8) else { return [] }
    return text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
}

private func decoder() -> JSONDecoder {
    let d = JSONDecoder()
    d.dateDecodingStrategy = .iso8601
    return d
}

private nonisolated func makeSummary(_ reply: String, entryID: UUID = UUID()) -> BellCaptureSummary {
    BellCaptureSummary(
        entryID: entryID,
        capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
        instructions: "i",
        prompt: "p",
        rawReply: reply,
        status: .ok,
        errorDescription: nil,
        elapsedSeconds: 0.5,
        sanitizedSummary: reply,
        feedRowText: reply
    )
}

// MARK: - Encoding

struct BellCaptureEncodingTests {
    private func makeEvent() -> BellCaptureEvent {
        BellCaptureEvent(
            entryID: UUID(),
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            appVersion: "1.3.2",
            appBuild: "42",
            windowID: UUID(),
            sessionID: UUID(),
            paneID: UUID(),
            tabID: UUID(),
            trigger: "cliNotification",
            message: "line one\nline two \"quoted\" /slash",
            messageTruncated: false,
            tabTitle: "zsh",
            tabLabel: "zsh",
            sessionTitle: "Work",
            foregroundProcess: nil,
            workingDirectory: nil,
            screen: nil,
            screenUnavailableReason: "unsupportedByTerminalHost",
            seenAtCreation: false,
            battyActive: false,
            sessionMuted: false,
            systemNotificationsEnabled: true,
            notifierPresent: true,
            collapse: BellCaptureCollapse(collapsed: false, repeatCount: 1, firstOccurrenceAt: Date(timeIntervalSince1970: 1_700_000_000)),
            notification: BellCaptureNotification(outcome: "suppressed", reason: "sessionMuted"),
            notificationTitle: nil,
            notificationBody: nil,
            feedRowPath: "Work › Pane 1 › zsh",
            feedRowText: "line one\nline two \"quoted\" /slash",
            summarization: .scheduled
        )
    }

    @Test func eventRoundTripsAndKeepsExplicitNulls() throws {
        let event = makeEvent()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(event)
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("\n"), "a record must encode as a single line")
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["schema"] as? Int == 1)
        #expect(object["type"] as? String == "event")
        for key in ["screen", "foregroundProcess", "workingDirectory", "notificationTitle", "notificationBody"] {
            #expect(object[key] is NSNull, "\(key) must be present as an explicit null")
        }
        #expect((object["notification"] as? [String: Any])?["reason"] as? String == "sessionMuted")
        let decoded = try decoder().decode(BellCaptureEvent.self, from: data)
        #expect(decoded == event)
    }

    @Test func summaryRoundTripsWithSchemaAndType() throws {
        let summary = makeSummary("tests passed")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(summary)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["schema"] as? Int == 1)
        #expect(object["type"] as? String == "summary")
        #expect(object["errorDescription"] is NSNull)
        #expect(try decoder().decode(BellCaptureSummary.self, from: data) == summary)
    }

    @Test func summaryStatusClassification() {
        let id = UUID()
        func status(_ result: NotificationSummarizationResult, cancelled: Bool = false, sanitized: String? = nil) -> BellCaptureSummaryStatus {
            AppStateStore.makeCaptureSummary(entryID: id, result: result, cancelled: cancelled, sanitized: sanitized, elapsedSeconds: 0, feedRowText: nil).status
        }
        #expect(status(.init(rawReply: "ok"), sanitized: "ok") == .ok)
        #expect(status(.init(rawReply: " none ")) == .none)
        #expect(status(.init(rawReply: "\"NONE\"")) == .none)
        #expect(status(.init(rawReply: "`none`")) == .none)
        #expect(status(.init(rawReply: String(repeating: "x", count: 500))) == .rejectedBySanitize)
        #expect(status(.init(failure: .modelUnavailable)) == .modelUnavailable)
        #expect(status(.init(failure: .cancelled)) == .cancelled)
        #expect(status(.init(failure: .timedOut)) == .timedOut)
        #expect(status(.init(rawReply: "late"), cancelled: true) == .cancelled)
        let failed = AppStateStore.makeCaptureSummary(entryID: id, result: .init(failure: .error("boom")), cancelled: false, sanitized: nil, elapsedSeconds: 0, feedRowText: nil)
        #expect(failed.status == .error)
        #expect(failed.errorDescription == "boom")
    }
}

// MARK: - Writer

struct BellCaptureWriterTests {
    @Test func appendsInOrderUnderConcurrentEnqueues() async throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let writer = BellCaptureWriter(directory: dir, maxRecords: 100_000)
        let producers = 8
        let perProducer = 50
        let padding = String(repeating: "z", count: 2_000)

        await withTaskGroup(of: Void.self) { group in
            for producer in 0..<producers {
                group.addTask {
                    for index in 0..<perProducer {
                        writer.enqueue(makeSummary("\(producer):\(index):\(padding)"))
                    }
                }
            }
        }
        let flushed = await awaitBounded { await writer.flush() }
        #expect(flushed)

        let lines = readLines(writer.currentFileURL)
        #expect(lines.count == producers * perProducer)
        var lastIndex: [Int: Int] = [:]
        for line in lines {
            let record = try decoder().decode(BellCaptureSummary.self, from: Data(line.utf8))
            let parts = try #require(record.rawReply).split(separator: ":", maxSplits: 2)
            let producer = try #require(Int(parts[0]))
            let index = try #require(Int(parts[1]))
            #expect(index == (lastIndex[producer] ?? -1) + 1, "records from one producer must stay in enqueue order")
            lastIndex[producer] = index
        }
    }

    @Test func rotatesAtRecordCap() async throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let writer = BellCaptureWriter(directory: dir, maxRecords: 5)
        for index in 0..<7 { writer.enqueue(makeSummary("r\(index)")) }
        #expect(await awaitBounded { await writer.flush() })

        #expect(readLines(writer.rotatedFileURL).count == 5)
        #expect(readLines(writer.currentFileURL).count == 2)
        let current = try readLines(writer.currentFileURL).map { try decoder().decode(BellCaptureSummary.self, from: Data($0.utf8)).rawReply }
        #expect(current == ["r5", "r6"])
    }

    @Test func rotationReplacesOlderGenerationAtSizeCap() async throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let writer = BellCaptureWriter(directory: dir, maxRecords: 1000, maxBytes: 1)
        for index in 0..<3 { writer.enqueue(makeSummary("s\(index)")) }
        #expect(await awaitBounded { await writer.flush() })

        let rotated = try readLines(writer.rotatedFileURL).map { try decoder().decode(BellCaptureSummary.self, from: Data($0.utf8)).rawReply }
        let current = try readLines(writer.currentFileURL).map { try decoder().decode(BellCaptureSummary.self, from: Data($0.utf8)).rawReply }
        #expect(rotated == ["s1"])
        #expect(current == ["s2"])
    }

    @Test func resumesCountingAnExistingFile() async throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = BellCaptureWriter(directory: dir, maxRecords: 3)
        for index in 0..<2 { first.enqueue(makeSummary("a\(index)")) }
        #expect(await awaitBounded { await first.flush() })

        let second = BellCaptureWriter(directory: dir, maxRecords: 3)
        for index in 0..<2 { second.enqueue(makeSummary("b\(index)")) }
        #expect(await awaitBounded { await second.flush() })

        #expect(readLines(second.rotatedFileURL).count == 3)
        #expect(readLines(second.currentFileURL).count == 1)
    }

    @Test func clearRemovesBothGenerationsAndWritingResumes() async throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let writer = BellCaptureWriter(directory: dir, maxRecords: 2)
        for index in 0..<3 { writer.enqueue(makeSummary("c\(index)")) }
        #expect(await awaitBounded { await writer.flush() })
        #expect(FileManager.default.fileExists(atPath: writer.rotatedFileURL.path))

        writer.clear()
        #expect(await awaitBounded { await writer.flush() })
        #expect(!FileManager.default.fileExists(atPath: writer.currentFileURL.path))
        #expect(!FileManager.default.fileExists(atPath: writer.rotatedFileURL.path))

        writer.enqueue(makeSummary("after"))
        #expect(await awaitBounded { await writer.flush() })
        #expect(readLines(writer.currentFileURL).count == 1)
    }

    @Test func unwritableDirectoryIsLoggedAndDoesNotThrow() async throws {
        let dir = makeTempDirectory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let blocker = dir.appendingPathComponent("not-a-directory")
        FileManager.default.createFile(atPath: blocker.path, contents: Data())
        let writer = BellCaptureWriter(directory: blocker.appendingPathComponent("nested"))

        writer.enqueue(makeSummary("lost"))
        #expect(await awaitBounded { await writer.flush() })
        #expect(await writer.currentFileExists() == false)
    }
}

// MARK: - Store integration

private final class StubSummarizer: NotificationSummarizing {
    var result: NotificationSummarizationResult
    init(_ result: NotificationSummarizationResult) { self.result = result }
    func summarize(message: String?, tabTitle: String?, sessionTitle: String?) async -> NotificationSummarizationResult { result }
}

@MainActor
final class AppStateStoreBellCaptureTests {
    private let testDefaults = TestDefaults()
    private let directory = makeTempDirectory()

    @MainActor deinit {
        testDefaults.tearDown()
        try? FileManager.default.removeItem(at: directory)
    }

    private struct Fixture {
        let store: AppStateStore
        let writer: BellCaptureWriter
        let notifier: SpyBellNotifier
        let tabID: UUID
    }

    private func makeFixture(capture: Bool, summarizer: NotificationSummarizing? = nil) -> Fixture {
        testDefaults.defaults.set(capture, forKey: SettingsPreference.captureBellFeedDataKey)
        let notifier = SpyBellNotifier()
        let store = AppStateStore(notifier: notifier, preferences: testDefaults.defaults)
        store.notificationSummarizer = summarizer
        let writer = BellCaptureWriter(directory: directory)
        store.bellCaptureWriter = writer
        let session = store.addSession(title: "Background")!
        store.selectedSessionID = store.sessions[0].id
        return Fixture(store: store, writer: writer, notifier: notifier, tabID: session.focusedPaneAnyKind.activeTabID)
    }

    private func records<T: Decodable>(_ type: T.Type, _ writer: BellCaptureWriter) async throws -> [T] {
        let writer = writer
        #expect(await awaitBounded { await writer.flush() })
        return try readLines(writer.currentFileURL).map { try decoder().decode(T.self, from: Data($0.utf8)) }
    }

    private func awaitTask(_ task: Task<Void, Never>) async {
        #expect(await awaitBounded { await task.value }, "summarization Task did not complete within the hang-guard bound")
    }

    @Test func toggleOffWritesNothingForAnyTrigger() async throws {
        let f = makeFixture(capture: false)
        let tab = f.store.sessions[1].focusedPaneAnyKind.activeTab!

        f.store.recordCLINotification(tabID: f.tabID, title: "Done", body: nil, playSound: false)
        tab.terminal.terminalDidRingBell()
        await awaitTerminalStatePublish { tab.terminal.bellCount >= 1 }
        f.store.recordBellTick(forTabID: tab.id)
        tab.terminal.terminalDidRequestDesktopNotification(title: "CI", body: "passed")
        await awaitTerminalStatePublish { tab.terminal.lastDesktopNotificationAt != nil }
        f.store.recordDesktopNotification(forTabID: tab.id)

        #expect(f.store.bellFeed.entries.count >= 1)
        let writer = f.writer
        #expect(await awaitBounded { await writer.flush() })
        #expect(await f.writer.currentFileExists() == false)
        #expect(!FileManager.default.fileExists(atPath: directory.path), "capture off must not even create the directory")
    }

    @Test func cliNotificationProducesAFullEventRecord() async throws {
        let f = makeFixture(capture: true)
        f.store.recordCLINotification(tabID: f.tabID, title: "Build", body: "failed: 3 errors", playSound: false)

        let events = try await records(BellCaptureEvent.self, f.writer)
        let event = try #require(events.first)
        #expect(events.count == 1)
        let entry = try #require(f.store.bellFeed.entries.first)
        #expect(event.entryID == entry.id)
        #expect(event.trigger == "cliNotification")
        #expect(event.message == "Build\nfailed: 3 errors")
        #expect(event.messageTruncated == false)
        #expect(event.sessionTitle == "Background")
        #expect(event.notification == BellCaptureNotification(outcome: "submitted", reason: nil))
        #expect(event.notificationBody == "Build\nfailed: 3 errors")
        #expect(event.notificationTitle == BellNotifier.notificationTitle(sessionTitle: "Background", paneIndex: 1, tabLabel: event.tabLabel))
        #expect(event.feedRowText == "Build\nfailed: 3 errors")
        #expect(event.feedRowPath.hasPrefix("Background"))
        #expect(event.collapse.collapsed == false)
        #expect(event.collapse.repeatCount == 1)
        #expect(event.seenAtCreation == false)
        #expect(event.summarization == .skippedNoSummarizer)
        #expect(event.screen == nil)
        #expect(event.screenUnavailableReason != nil)
        let decision = try #require(f.store.bellDecisionHistory.records.last)
        #expect(decision.outcome == .submitted)
    }

    @Test func bellAndDesktopNotificationTriggersEachProduceOneEvent() async throws {
        let f = makeFixture(capture: true)
        let tab = f.store.sessions[1].focusedPaneAnyKind.activeTab!

        tab.terminal.terminalDidRingBell()
        await awaitTerminalStatePublish { tab.terminal.bellCount >= 1 }
        f.store.recordBellTick(forTabID: tab.id)
        tab.terminal.terminalDidRequestDesktopNotification(title: "CI", body: "passed")
        await awaitTerminalStatePublish { tab.terminal.lastDesktopNotificationAt != nil }
        f.store.recordDesktopNotification(forTabID: tab.id)

        let events = try await records(BellCaptureEvent.self, f.writer)
        #expect(events.map(\.trigger) == ["bel", "oscNotification"])
        #expect(events[0].message == nil)
        #expect(events[0].notificationBody == "Bell")
        #expect(events[0].feedRowText == nil)
    }

    @Test func collapsedRepeatJoinsOnTheSurvivingEntry() async throws {
        let f = makeFixture(capture: true)
        f.store.recordCLINotification(tabID: f.tabID, title: "waiting", body: nil, playSound: false)
        f.store.recordCLINotification(tabID: f.tabID, title: "waiting", body: nil, playSound: false)

        let events = try await records(BellCaptureEvent.self, f.writer)
        #expect(events.count == 2)
        let surviving = try #require(f.store.bellFeed.entries.first)
        #expect(f.store.bellFeed.entries.count == 1)
        #expect(events.map(\.entryID) == [surviving.id, surviving.id])
        #expect(events[1].collapse.collapsed == true)
        #expect(events[1].collapse.repeatCount == 2)
        #expect(events[1].collapse.firstOccurrenceAt == events[0].collapse.firstOccurrenceAt)
        #expect(events[1].notification == BellCaptureNotification(outcome: "suppressed", reason: "collapsedIntoUnread"))
        #expect(events[1].notificationTitle == nil)
        #expect(events[1].notificationBody == nil)
        #expect(events[1].summarization == .notApplicableCollapsed)
        #expect(f.store.bellDecisionHistory.records.last?.outcome == .suppressed(.collapsedIntoUnread))
    }

    @Test func suppressedOutcomeMatchesTheDecisionRecord() async throws {
        let f = makeFixture(capture: true)
        f.store.sessions[1].notificationsMuted = true
        f.store.recordCLINotification(tabID: f.tabID, title: "quiet", body: nil, playSound: false)

        let event = try #require(try await records(BellCaptureEvent.self, f.writer).first)
        #expect(event.notification == BellCaptureNotification(outcome: "suppressed", reason: "sessionMuted"))
        #expect(event.sessionMuted == true)
        #expect(f.store.bellDecisionHistory.records.last?.outcome == .suppressed(.sessionMuted))
    }

    @Test func summaryRecordCarriesPromptRawReplyAndJoinsByEntryID() async throws {
        let summarizer = StubSummarizer(.init(instructions: "the instructions", prompt: "the prompt", rawReply: "  \"build failed\"  "))
        let f = makeFixture(capture: true, summarizer: summarizer)
        f.store.recordCLINotification(tabID: f.tabID, title: "Build", body: "boom", playSound: false)
        let entryID = try #require(f.store.bellFeed.entries.first?.id)
        let task = try #require(f.store.summarizationTaskForTesting(entryID: entryID))
        await awaitTask(task)

        let writer = f.writer
        #expect(await awaitBounded { await writer.flush() })
        let lines = readLines(f.writer.currentFileURL)
        #expect(lines.count == 2)
        let event = try decoder().decode(BellCaptureEvent.self, from: Data(lines[0].utf8))
        let summary = try decoder().decode(BellCaptureSummary.self, from: Data(lines[1].utf8))
        #expect(event.summarization == .scheduled)
        #expect(event.feedRowText == "Build\nboom")
        #expect(summary.entryID == event.entryID)
        #expect(summary.instructions == "the instructions")
        #expect(summary.prompt == "the prompt")
        #expect(summary.rawReply == "  \"build failed\"  ")
        #expect(summary.status == .ok)
        #expect(summary.sanitizedSummary == "build failed")
        #expect(summary.feedRowText == "build failed")
        #expect(summary.elapsedSeconds >= 0)
        #expect(f.store.bellFeed.entries.first?.summary == "build failed")
    }

    @Test func noneAndRejectedRepliesAreRecordedWithoutUpdatingTheFeed() async throws {
        let summarizer = StubSummarizer(.init(prompt: "p", rawReply: "NONE"))
        let f = makeFixture(capture: true, summarizer: summarizer)
        f.store.recordCLINotification(tabID: f.tabID, title: "one", body: nil, playSound: false)
        let first = try #require(f.store.bellFeed.entries.first?.id)
        await awaitTask(try #require(f.store.summarizationTaskForTesting(entryID: first)))

        summarizer.result = .init(prompt: "p", rawReply: String(repeating: "x", count: NotificationSummary.maxLength + 1))
        f.store.recordCLINotification(tabID: f.tabID, title: "two", body: nil, playSound: false)
        let second = try #require(f.store.bellFeed.entries.first?.id)
        await awaitTask(try #require(f.store.summarizationTaskForTesting(entryID: second)))

        let writer = f.writer
        #expect(await awaitBounded { await writer.flush() })
        let summaries = try readLines(f.writer.currentFileURL)
            .map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] ?? [:] }
            .filter { $0["type"] as? String == "summary" }
        #expect(summaries.map { $0["status"] as? String } == ["none", "rejectedBySanitize"])
        #expect(summaries.allSatisfy { $0["sanitizedSummary"] is NSNull })
        #expect(summaries[0]["feedRowText"] as? String == "one")
        #expect(f.store.bellFeed.entries.allSatisfy { $0.summary == nil })
    }

    @Test func failureStatusAndErrorDescriptionReachTheCapture() async throws {
        let summarizer = StubSummarizer(.init(prompt: "p", failure: .error("model exploded")))
        let f = makeFixture(capture: true, summarizer: summarizer)
        f.store.recordCLINotification(tabID: f.tabID, title: "x", body: nil, playSound: false)
        let id = try #require(f.store.bellFeed.entries.first?.id)
        await awaitTask(try #require(f.store.summarizationTaskForTesting(entryID: id)))

        let writer = f.writer
        #expect(await awaitBounded { await writer.flush() })
        let lines = readLines(f.writer.currentFileURL)
        let summary = try decoder().decode(BellCaptureSummary.self, from: Data(try #require(lines.last).utf8))
        #expect(summary.status == .error)
        #expect(summary.errorDescription == "model exploded")
        #expect(summary.rawReply == nil)
    }

    @Test func noSummaryRecordWhenCaptureWasOffAtEventTime() async throws {
        let summarizer = StubSummarizer(.init(prompt: "p", rawReply: "done"))
        let f = makeFixture(capture: false, summarizer: summarizer)
        f.store.recordCLINotification(tabID: f.tabID, title: "x", body: nil, playSound: false)
        let id = try #require(f.store.bellFeed.entries.first?.id)
        f.store.preferences.set(true, forKey: SettingsPreference.captureBellFeedDataKey)
        await awaitTask(try #require(f.store.summarizationTaskForTesting(entryID: id)))

        let writer = f.writer
        #expect(await awaitBounded { await writer.flush() })
        #expect(await f.writer.currentFileExists() == false, "a summary must never be written without its event")
    }

    @Test func summaryInFlightAcrossClearIsDropped() async throws {
        let summarizer = StubSummarizer(.init(prompt: "p", rawReply: "late summary"))
        let f = makeFixture(capture: true, summarizer: summarizer)
        f.store.recordCLINotification(tabID: f.tabID, title: "x", body: nil, playSound: false)
        let id = try #require(f.store.bellFeed.entries.first?.id)
        let task = try #require(f.store.summarizationTaskForTesting(entryID: id))

        f.writer.clear()
        await awaitTask(task)

        let writer = f.writer
        #expect(await awaitBounded { await writer.flush() })
        #expect(readLines(f.writer.currentFileURL).isEmpty, "an orphan summary must not land in the fresh file")
        #expect(f.store.bellFeed.entries.first?.summary == "late summary")
    }

    @Test func emptyMessageFeedRowTextIsNull() async throws {
        let f = makeFixture(capture: true)
        f.store.recordCLINotification(tabID: f.tabID, title: "", body: nil, playSound: false)
        let event = try #require(try await records(BellCaptureEvent.self, f.writer).first)
        #expect(event.message == "")
        #expect(event.feedRowText == nil)
    }

    @Test func skippedSummarizationReasonsAreRecorded() async throws {
        let off = makeFixture(capture: true, summarizer: StubSummarizer(.init(rawReply: "x")))
        off.store.preferences.set(false, forKey: SettingsPreference.summarizeNotificationsWithAIKey)
        off.store.recordCLINotification(tabID: off.tabID, title: "x", body: nil, playSound: false)
        let offEvents = try await records(BellCaptureEvent.self, off.writer)
        #expect(offEvents.map(\.summarization) == [.skippedDisabled])
    }
}
