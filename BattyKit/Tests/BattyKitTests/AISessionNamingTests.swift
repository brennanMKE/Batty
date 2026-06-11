// AISessionNamingTests.swift

import Foundation
import Testing
@testable import BattyKit

/// Test double for the AI naming step: returns a canned result and records
/// every path it was asked about.
private final class RecordingSuggester: SessionNameSuggesting {
    var result: String?
    private(set) var requestedPaths: [String] = []

    init(result: String?) {
        self.result = result
    }

    func suggestName(forPath path: String) async -> String? {
        requestedPaths.append(path)
        return result
    }
}

@MainActor
struct AISessionNamingTests {

    private func makeStore(suggester: SessionNameSuggesting?) -> (AppStateStore, URL) {
        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("batty-ai-naming-\(UUID().uuidString)")
            .appendingPathComponent("session-name-cache.json")
        let cache = SessionNameCache(fileURL: cacheURL, debounce: .zero)
        let store = AppStateStore(nameCache: cache)
        store.nameSuggester = suggester
        return (store, cacheURL)
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    private func awaitSuggestion(_ store: AppStateStore, sessionID: UUID) async {
        if let inflight = store.nameSuggestionTasks[sessionID] {
            await inflight.task.value
        }
    }

    // MARK: - Gating: AI runs only when the deterministic chain misses

    @Test func aiSuggestionAppliesWhenCacheAndRulesMiss() async {
        let suggester = RecordingSuggester(result: "Meeting Notes")
        let (store, url) = makeStore(suggester: suggester)
        defer { cleanup(url) }

        let session = store.sessions[0]
        let anchorTab = session.tree.root.firstLeafPane.tabs[0]
        anchorTab.terminal.configuration.workingDirectory = "/Users/test/meeting notes 2026"
        store.handleWorkingDirectoryChange(forTabID: anchorTab.id)

        #expect(session.title == "Session 1")
        await awaitSuggestion(store, sessionID: session.id)

        #expect(session.title == "Meeting Notes")
        #expect(session.titleOverride == false)
        #expect(suggester.requestedPaths == ["/Users/test/meeting notes 2026"])
    }

    @Test func aiStepSkippedOnCacheHit() async {
        let suggester = RecordingSuggester(result: "AI Name")
        let (store, url) = makeStore(suggester: suggester)
        defer { cleanup(url) }
        store.nameCache.record(path: "/Users/test/Developer/Batty", name: "Batty")

        let session = store.sessions[0]
        let anchorTab = session.tree.root.firstLeafPane.tabs[0]
        anchorTab.terminal.configuration.workingDirectory = "/Users/test/Developer/Batty"
        store.handleWorkingDirectoryChange(forTabID: anchorTab.id)
        await awaitSuggestion(store, sessionID: session.id)

        #expect(session.title == "Batty")
        #expect(suggester.requestedPaths.isEmpty)
        #expect(store.nameSuggestionTasks[session.id] == nil)
    }

    @Test func aiStepSkippedOnProjectRuleMatch() async throws {
        let projectDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("batty-ai-project-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: projectDir.appendingPathComponent("Demo.xcodeproj"),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: projectDir) }

        let suggester = RecordingSuggester(result: "AI Name")
        let (store, url) = makeStore(suggester: suggester)
        defer { cleanup(url) }

        let session = store.sessions[0]
        let anchorTab = session.tree.root.firstLeafPane.tabs[0]
        anchorTab.terminal.configuration.workingDirectory = projectDir.path
        store.handleWorkingDirectoryChange(forTabID: anchorTab.id)
        await awaitSuggestion(store, sessionID: session.id)

        #expect(session.title == "Demo")
        #expect(suggester.requestedPaths.isEmpty)
    }

    @Test func nilSuggesterLeavesChainUnchanged() {
        let (store, url) = makeStore(suggester: nil)
        defer { cleanup(url) }

        let session = store.sessions[0]
        let anchorTab = session.tree.root.firstLeafPane.tabs[0]
        anchorTab.terminal.configuration.workingDirectory = "/Users/test/no-project-here"
        store.handleWorkingDirectoryChange(forTabID: anchorTab.id)

        #expect(session.title == "Session 1")
        #expect(store.nameSuggestionTasks[session.id] == nil)
    }

    // MARK: - NONE / junk / error outcomes keep the default

    @Test func noneResultLeavesDefaultAndIsMemoizedWithoutReprompt() async {
        let suggester = RecordingSuggester(result: nil)
        let (store, url) = makeStore(suggester: suggester)
        defer { cleanup(url) }

        let session = store.sessions[0]
        let anchorTab = session.tree.root.firstLeafPane.tabs[0]
        anchorTab.terminal.configuration.workingDirectory = "/Users/test/untitled folder 3"
        store.handleWorkingDirectoryChange(forTabID: anchorTab.id)
        await awaitSuggestion(store, sessionID: session.id)

        #expect(session.title == "Session 1")

        // Repeat report of the same cwd: the NONE memo answers, no re-prompt.
        store.handleWorkingDirectoryChange(forTabID: anchorTab.id)
        await awaitSuggestion(store, sessionID: session.id)

        #expect(session.title == "Session 1")
        #expect(suggester.requestedPaths.count == 1)
    }

    @Test func junkSuggestionLeavesDefault() async {
        let suggester = RecordingSuggester(
            result: "This response is definitely way too long, punctuated, and useless!"
        )
        let (store, url) = makeStore(suggester: suggester)
        defer { cleanup(url) }

        let session = store.sessions[0]
        let anchorTab = session.tree.root.firstLeafPane.tabs[0]
        anchorTab.terminal.configuration.workingDirectory = "/Users/test/junk-folder"
        store.handleWorkingDirectoryChange(forTabID: anchorTab.id)
        await awaitSuggestion(store, sessionID: session.id)

        #expect(session.title == "Session 1")
    }

    // MARK: - Staleness and pinning

    @Test func staleCwdResultIsDropped() async {
        let suggester = RecordingSuggester(result: "Cool Name")
        let (store, url) = makeStore(suggester: suggester)
        defer { cleanup(url) }

        let session = store.sessions[0]
        let anchorTab = session.tree.root.firstLeafPane.tabs[0]
        anchorTab.terminal.configuration.workingDirectory = "/Users/test/folder-a"
        store.handleWorkingDirectoryChange(forTabID: anchorTab.id)
        let inflight = store.nameSuggestionTasks[session.id]
        #expect(inflight != nil)

        // The shell moves on before the model answers.
        anchorTab.terminal.configuration.workingDirectory = "/Users/test/folder-b"
        await inflight?.task.value

        #expect(session.title == "Session 1")
    }

    @Test func userRenamePinsAgainstLateSuggestion() async {
        let suggester = RecordingSuggester(result: "Cool Name")
        let (store, url) = makeStore(suggester: suggester)
        defer { cleanup(url) }

        let session = store.sessions[0]
        let anchorTab = session.tree.root.firstLeafPane.tabs[0]
        anchorTab.terminal.configuration.workingDirectory = "/Users/test/folder-a"
        store.handleWorkingDirectoryChange(forTabID: anchorTab.id)
        let inflight = store.nameSuggestionTasks[session.id]

        store.renameSession(id: session.id, to: "Frontend")
        await inflight?.task.value

        #expect(session.title == "Frontend")
        #expect(session.titleOverride == true)
    }

    @Test func splitBeforeResultDropsSuggestion() async {
        let suggester = RecordingSuggester(result: "Cool Name")
        let (store, url) = makeStore(suggester: suggester)
        defer { cleanup(url) }

        let session = store.sessions[0]
        let anchorTab = session.tree.root.firstLeafPane.tabs[0]
        anchorTab.terminal.configuration.workingDirectory = "/Users/test/folder-a"
        store.handleWorkingDirectoryChange(forTabID: anchorTab.id)
        let inflight = store.nameSuggestionTasks[session.id]

        session.tree.splitFocusedPane(direction: .horizontal)
        await inflight?.task.value

        #expect(session.title == "Session 1")
    }

    @Test func repeatReportOfSameCwdDoesNotRestartRequest() async {
        let suggester = RecordingSuggester(result: "Cool Name")
        let (store, url) = makeStore(suggester: suggester)
        defer { cleanup(url) }

        let session = store.sessions[0]
        let anchorTab = session.tree.root.firstLeafPane.tabs[0]
        anchorTab.terminal.configuration.workingDirectory = "/Users/test/folder-a"
        store.handleWorkingDirectoryChange(forTabID: anchorTab.id)
        store.handleWorkingDirectoryChange(forTabID: anchorTab.id)
        await awaitSuggestion(store, sessionID: session.id)

        #expect(session.title == "Cool Name")
        #expect(suggester.requestedPaths.count == 1)
    }

    @Test func memoReappliesWithoutRepromptAfterRoundTrip() async {
        let suggester = RecordingSuggester(result: "Cool Name")
        let (store, url) = makeStore(suggester: suggester)
        defer { cleanup(url) }
        store.nameCache.record(path: "/Users/test/Developer/Batty", name: "Batty")

        let session = store.sessions[0]
        let anchorTab = session.tree.root.firstLeafPane.tabs[0]
        anchorTab.terminal.configuration.workingDirectory = "/Users/test/folder-a"
        store.handleWorkingDirectoryChange(forTabID: anchorTab.id)
        await awaitSuggestion(store, sessionID: session.id)
        #expect(session.title == "Cool Name")

        // Visit a cached project, then come back: memo answers synchronously.
        anchorTab.terminal.configuration.workingDirectory = "/Users/test/Developer/Batty"
        store.handleWorkingDirectoryChange(forTabID: anchorTab.id)
        #expect(session.title == "Batty")

        anchorTab.terminal.configuration.workingDirectory = "/Users/test/folder-a"
        store.handleWorkingDirectoryChange(forTabID: anchorTab.id)

        #expect(session.title == "Cool Name")
        #expect(suggester.requestedPaths.count == 1)
        #expect(store.nameSuggestionTasks[session.id] == nil)
    }

    // MARK: - AI names are ephemeral: never cached, never persisted

    @Test func aiNameIsNeverWrittenToSessionNameCache() async {
        let suggester = RecordingSuggester(result: "Meeting Notes")
        let (store, url) = makeStore(suggester: suggester)
        defer { cleanup(url) }

        let session = store.sessions[0]
        let anchorTab = session.tree.root.firstLeafPane.tabs[0]
        anchorTab.terminal.configuration.workingDirectory = "/Users/test/meeting notes 2026"
        store.handleWorkingDirectoryChange(forTabID: anchorTab.id)
        await awaitSuggestion(store, sessionID: session.id)

        #expect(session.title == "Meeting Notes")
        #expect(session.titleOverride == false)
        #expect(store.nameCache.snapshot().isEmpty)
        #expect(store.nameCache.lookup(path: "/Users/test/meeting notes 2026") == nil)
    }

    @Test func persistenceRoundTripReResolvesInsteadOfRestoringAITitle() async {
        let suggester = RecordingSuggester(result: "Meeting Notes")
        let (store, url) = makeStore(suggester: suggester)
        defer { cleanup(url) }

        let session = store.sessions[0]
        let anchorTab = session.tree.root.firstLeafPane.tabs[0]
        anchorTab.terminal.configuration.workingDirectory = "/Users/test/meeting notes 2026"
        store.handleWorkingDirectoryChange(forTabID: anchorTab.id)
        await awaitSuggestion(store, sessionID: session.id)
        #expect(session.title == "Meeting Notes")
        store.nameCache.save()

        // "Relaunch": a fresh cache from the same file plus a fresh store
        // (no suggester) must fall back to the default, not the AI name.
        let restoredCache = SessionNameCache(fileURL: url, debounce: .zero)
        #expect(restoredCache.lookup(path: "/Users/test/meeting notes 2026") == nil)

        let restoredStore = AppStateStore(nameCache: restoredCache)
        let restoredSession = restoredStore.sessions[0]
        let restoredTab = restoredSession.tree.root.firstLeafPane.tabs[0]
        restoredTab.terminal.configuration.workingDirectory = "/Users/test/meeting notes 2026"
        restoredStore.handleWorkingDirectoryChange(forTabID: restoredTab.id)

        #expect(restoredSession.title == "Session 1")
    }

    // MARK: - Sanitizer

    @Test func sanitizeAcceptsShortCleanNames() {
        #expect(SessionNameSuggestion.sanitize("Meeting Notes") == "Meeting Notes")
        #expect(SessionNameSuggestion.sanitize("  Batty Website  ") == "Batty Website")
        #expect(SessionNameSuggestion.sanitize("\"Quoted Name\"") == "Quoted Name")
        #expect(SessionNameSuggestion.sanitize("Notes") == "Notes")
        #expect(SessionNameSuggestion.sanitize("Q2 budget-draft files") == "Q2 budget-draft files")
    }

    @Test func sanitizeRejectsNoneEmptyAndJunk() {
        #expect(SessionNameSuggestion.sanitize("NONE") == nil)
        #expect(SessionNameSuggestion.sanitize("none") == nil)
        #expect(SessionNameSuggestion.sanitize(" \"NONE\" ") == nil)
        #expect(SessionNameSuggestion.sanitize("") == nil)
        #expect(SessionNameSuggestion.sanitize("   ") == nil)
        #expect(SessionNameSuggestion.sanitize("one two three four five") == nil)
        #expect(SessionNameSuggestion.sanitize("An extremely long suggestion that rambles on") == nil)
        #expect(SessionNameSuggestion.sanitize("Name: with punctuation!") == nil)
        #expect(SessionNameSuggestion.sanitize("Line\nBreak") == nil)
    }
}
