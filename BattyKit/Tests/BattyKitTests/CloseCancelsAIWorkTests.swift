// CloseCancelsAIWorkTests.swift

import Foundation
import Testing
@testable import BattyKit

/// Parks every `suggestName` call until `open()`, and records each path it
/// was asked about.
private final class GatedSuggester: SessionNameSuggesting {
    let result: String
    private(set) var requestedPaths: [String] = []
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var startWaiters: [(count: Int, once: ResumeOnce<Bool>)] = []

    init(result: String = "Suggested") { self.result = result }

    func open() {
        isOpen = true
        let parked = waiters
        waiters = []
        parked.forEach { $0.resume() }
    }

    func waitUntilStarted(_ count: Int) async -> Bool {
        if requestedPaths.count >= count { return true }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let once = ResumeOnce(continuation)
            let timeout = DispatchWorkItem { once.resume(false) }
            once.setOnResumed { timeout.cancel() }
            startWaiters.append((count, once))
            DispatchQueue.main.asyncAfter(deadline: .now() + TestBounds.hangGuard, execute: timeout)
        }
    }

    func suggestName(forPath path: String) async -> String? {
        requestedPaths.append(path)
        let reached = startWaiters.filter { requestedPaths.count >= $0.count }
        startWaiters.removeAll { requestedPaths.count >= $0.count }
        reached.forEach { $0.once.resume(true) }
        if !isOpen {
            await withCheckedContinuation { waiters.append($0) }
        }
        return result
    }
}

private final class GatedSummarizer: NotificationSummarizing {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        isOpen = true
        let parked = waiters
        waiters = []
        parked.forEach { $0.resume() }
    }

    func summarize(message: String?, tabTitle: String?, sessionTitle: String?) async -> NotificationSummarizationResult {
        if !isOpen {
            await withCheckedContinuation { waiters.append($0) }
        }
        return .init(prompt: "p", rawReply: "summary")
    }
}

/// Every close path cancels the closed Tabs' and Sessions' AI naming work,
/// and a row leaving the Bell Feed cancels its summarization (#0564).
@MainActor
final class CloseCancelsAIWorkTests {
    private let testDefaults = TestDefaults()
    private let cacheDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("batty-close-cancels-ai-\(UUID().uuidString)")
    private var nextProject = 0

    @MainActor deinit {
        testDefaults.tearDown()
        try? FileManager.default.removeItem(at: cacheDirectory)
    }

    private func makeStore(_ suggester: GatedSuggester, summarizer: GatedSummarizer? = nil) -> AppStateStore {
        let cache = SessionNameCache(
            fileURL: cacheDirectory.appendingPathComponent("session-name-cache.json"),
            debounce: .zero,
            homeDirectory: "/Users/test"
        )
        testDefaults.defaults.set(false, forKey: SettingsPreference.captureBellFeedDataKey)
        let store = AppStateStore(nameCache: cache, preferences: testDefaults.defaults)
        store.isBattyActiveProvider = { false }
        store.nameSuggester = suggester
        store.notificationSummarizer = summarizer
        store.preferences.set(true, forKey: SettingsPreference.autoNameWithAIKey)
        return store
    }

    private func nextCWD() -> String {
        nextProject += 1
        return "/Users/test/project-\(nextProject)"
    }

    @discardableResult
    private func startTabSuggestion(_ store: AppStateStore, _ tab: TabRuntime) throws -> Task<Void, Never> {
        tab.terminal.configuration.workingDirectory = nextCWD()
        store.updateTabAutoName(for: tab)
        return try #require(store.tabNameSuggestionTasks[tab.id]?.task)
    }

    @discardableResult
    private func startSessionSuggestion(_ store: AppStateStore, _ session: SessionRuntime) throws -> Task<Void, Never> {
        let anchor = session.tree.root.firstLeafPane.tabs[0]
        anchor.terminal.configuration.workingDirectory = nextCWD()
        store.handleWorkingDirectoryChange(forTabID: anchor.id)
        return try #require(store.nameSuggestionTasks[session.id]?.task)
    }

    private func cwd(_ tab: TabRuntime) -> String? { tab.terminal.configuration.workingDirectory }

    private func awaitTask(_ task: Task<Void, Never>) async {
        #expect(await awaitBounded { await task.value }, "Task did not complete within the hang-guard bound")
    }

    private func expectTabCancelled(_ store: AppStateStore, _ suggester: GatedSuggester,
                                    _ tab: TabRuntime, _ task: Task<Void, Never>) async {
        #expect(store.tabNameSuggestionTasks[tab.id] == nil)
        #expect(task.isCancelled)
        await awaitTask(task)
        #expect(!suggester.requestedPaths.contains { $0 == cwd(tab) })
    }

    private func expectSessionCancelled(_ store: AppStateStore, _ suggester: GatedSuggester,
                                        _ session: SessionRuntime, cwd sessionCWD: String?,
                                        _ task: Task<Void, Never>) async {
        #expect(store.nameSuggestionTasks[session.id] == nil)
        #expect(task.isCancelled)
        await awaitTask(task)
        #expect(!suggester.requestedPaths.contains { $0 == sessionCWD })
    }

    /// A background Session with two idle Tabs and a Reminder row, so the
    /// Session's own state is non-default when one Tab closes.
    private func backgroundSession(_ store: AppStateStore) throws -> (SessionRuntime, PaneRuntime, UUID) {
        let session = try #require(store.addSession())
        let pane = session.tree.allPanes[0]
        pane.addTab()
        store.selectedSessionID = store.sessions[0].id
        let window = store.windows[0]
        let reminder = BellFeedEntry(timestamp: Date(), windowID: window.id.value, sessionID: session.id,
                                     paneID: pane.id, tabID: pane.tabs[0].id, surfaceID: UUID(),
                                     message: "Reminder", kind: .reminder)
        store.bellFeed.entries.insert(reminder, at: 0)
        return (session, pane, reminder.id)
    }

    // MARK: - Tab name, one per close path

    @Test func chipCloseCancelsTheTabsNameSuggestion() async throws {
        let suggester = GatedSuggester()
        let store = makeStore(suggester)
        defer { suggester.open() }
        let (_, pane, reminderID) = try backgroundSession(store)
        let tab = pane.tabs[1]
        let task = try startTabSuggestion(store, tab)

        store.requestCloseTab(id: tab.id)

        #expect(!pane.tabs.contains { $0.id == tab.id })
        #expect(store.bellFeed.entries.contains { $0.id == reminderID })
        await expectTabCancelled(store, suggester, tab, task)
    }

    @Test func cmdWCancelsTheFocusedTabsNameSuggestion() async throws {
        let suggester = GatedSuggester()
        let store = makeStore(suggester)
        defer { suggester.open() }
        let window = store.windows[0]
        let pane = store.sessions[0].tree.allPanes[0]
        let tab = pane.addTab()
        pane.activeTabID = tab.id
        let task = try startTabSuggestion(store, tab)

        window.closeFocusedTab()

        #expect(!pane.tabs.contains { $0.id == tab.id })
        await expectTabCancelled(store, suggester, tab, task)
    }

    @Test func menuAndPaletteCloseTabCancelsTheFocusedTabsNameSuggestion() async throws {
        let suggester = GatedSuggester()
        let store = makeStore(suggester)
        defer { suggester.open() }
        let window = store.windows[0]
        let pane = store.sessions[0].tree.allPanes[0]
        let tab = pane.addTab()
        pane.activeTabID = tab.id
        let task = try startTabSuggestion(store, tab)

        window.requestCloseFocusedTab()

        #expect(!pane.tabs.contains { $0.id == tab.id })
        await expectTabCancelled(store, suggester, tab, task)
    }

    @Test func shellExitCloseStillCancelsTheNameSuggestion() async throws {
        let suggester = GatedSuggester()
        let store = makeStore(suggester)
        defer { suggester.open() }
        let (_, pane, _) = try backgroundSession(store)
        let tab = pane.tabs[1]
        let task = try startTabSuggestion(store, tab)

        store.closeTab(id: tab.id)

        await expectTabCancelled(store, suggester, tab, task)
    }

    @Test func confirmedSingleTabCloseCancelsTheNameSuggestion() async throws {
        let suggester = GatedSuggester()
        let store = makeStore(suggester)
        defer { suggester.open() }
        let window = store.windows[0]
        let (_, pane, _) = try backgroundSession(store)
        let tab = pane.tabs[1]
        tab.needsConfirmCloseOverride = true
        let task = try startTabSuggestion(store, tab)

        store.requestCloseTab(id: tab.id)
        #expect(window.pendingCloseRequest != nil)
        #expect(!task.isCancelled)

        window.confirmPendingClose()

        await expectTabCancelled(store, suggester, tab, task)
    }

    @Test func cancelledCloseDialogKeepsTheNameSuggestion() async throws {
        let suggester = GatedSuggester()
        let store = makeStore(suggester)
        defer { suggester.open() }
        let window = store.windows[0]
        let (_, pane, _) = try backgroundSession(store)
        let tab = pane.tabs[1]
        tab.needsConfirmCloseOverride = true
        let task = try startTabSuggestion(store, tab)

        store.requestCloseTab(id: tab.id)
        store.cancelPendingClose()

        #expect(window.pendingCloseRequest == nil)
        #expect(!task.isCancelled)
        #expect(store.tabNameSuggestionTasks[tab.id] != nil)
        suggester.open()
        await awaitTask(task)
        #expect(tab.aiSuggestedName == "Suggested")
    }

    @Test func closeOtherTabsCancelsOnlyTheClosedTabsSuggestions() async throws {
        let suggester = GatedSuggester()
        let store = makeStore(suggester)
        defer { suggester.open() }
        let (_, pane, _) = try backgroundSession(store)
        pane.addTab()
        let victim1 = pane.tabs[0], kept = pane.tabs[1], victim2 = pane.tabs[2]
        pane.activeTabID = victim2.id
        let task1 = try startTabSuggestion(store, victim1)
        let keptTask = try startTabSuggestion(store, kept)
        let task2 = try startTabSuggestion(store, victim2)

        store.requestCloseOtherTabs(paneID: pane.id, keepingTabID: kept.id)

        #expect(pane.tabs.map(\.id) == [kept.id])
        #expect(!keptTask.isCancelled)
        #expect(store.tabNameSuggestionTasks[kept.id] != nil)
        await expectTabCancelled(store, suggester, victim1, task1)
        await expectTabCancelled(store, suggester, victim2, task2)
        suggester.open()
        await awaitTask(keptTask)
        #expect(kept.aiSuggestedName == "Suggested")
    }

    @Test func confirmedCloseOtherTabsCancelsTheClosedTabsSuggestions() async throws {
        let suggester = GatedSuggester()
        let store = makeStore(suggester)
        defer { suggester.open() }
        let window = store.windows[0]
        let (_, pane, _) = try backgroundSession(store)
        let victim = pane.tabs[0], kept = pane.tabs[1]
        victim.needsConfirmCloseOverride = true
        let task = try startTabSuggestion(store, victim)

        store.requestCloseOtherTabs(paneID: pane.id, keepingTabID: kept.id)
        #expect(window.pendingCloseRequest != nil)
        #expect(!task.isCancelled)
        window.confirmPendingClose()

        await expectTabCancelled(store, suggester, victim, task)
    }

    @Test func closePaneCancelsEveryTabSuggestionInThePaneOnly() async throws {
        let suggester = GatedSuggester()
        let store = makeStore(suggester)
        defer { suggester.open() }
        let session = try #require(store.addSession())
        let paneA = session.tree.allPanes[0]
        let paneBID = try #require(store.splitPane(id: paneA.id, direction: .horizontal))
        let paneB = try #require(session.tree.allPanes.first { $0.id == paneBID })
        paneB.addTab()
        let tabA = paneA.tabs[0], b1 = paneB.tabs[0], b2 = paneB.tabs[1]
        let taskA = try startTabSuggestion(store, tabA)
        let task1 = try startTabSuggestion(store, b1)
        let task2 = try startTabSuggestion(store, b2)

        #expect(store.closePane(id: paneBID) == .closed)

        await expectTabCancelled(store, suggester, b1, task1)
        await expectTabCancelled(store, suggester, b2, task2)
        #expect(!taskA.isCancelled)
        #expect(store.tabNameSuggestionTasks[tabA.id] != nil)
        suggester.open()
        await awaitTask(taskA)
        #expect(tabA.aiSuggestedName == "Suggested")
    }

    @Test func sidebarCloseSessionCancelsEveryTabAndTheSessionSuggestion() async throws {
        let suggester = GatedSuggester()
        let store = makeStore(suggester)
        defer { suggester.open() }
        let window = store.windows[0]
        let (session, pane, _) = try backgroundSession(store)
        pane.addTab()
        let sessionTask = try startSessionSuggestion(store, session)
        let sessionCWD = cwd(pane.tabs[0])
        let t1 = pane.tabs[1], t2 = pane.tabs[2]
        let task1 = try startTabSuggestion(store, t1)
        let task2 = try startTabSuggestion(store, t2)

        window.requestRemoveSession(id: session.id)

        #expect(!store.sessions.contains { $0.id == session.id })
        await expectSessionCancelled(store, suggester, session, cwd: sessionCWD, sessionTask)
        await expectTabCancelled(store, suggester, t1, task1)
        await expectTabCancelled(store, suggester, t2, task2)
    }

    @Test func confirmedSessionCloseCancelsItsSuggestions() async throws {
        let suggester = GatedSuggester()
        let store = makeStore(suggester)
        defer { suggester.open() }
        let window = store.windows[0]
        let (session, pane, _) = try backgroundSession(store)
        let sessionTask = try startSessionSuggestion(store, session)
        let sessionCWD = cwd(pane.tabs[0])
        let busy = pane.tabs[1]
        busy.needsConfirmCloseOverride = true
        let tabTask = try startTabSuggestion(store, busy)

        window.requestRemoveSession(id: session.id)
        #expect(window.pendingCloseRequest != nil)
        #expect(!sessionTask.isCancelled)
        window.confirmPendingClose()

        await expectSessionCancelled(store, suggester, session, cwd: sessionCWD, sessionTask)
        await expectTabCancelled(store, suggester, busy, tabTask)
    }

    @Test func cliSessionCloseCancelsItsSuggestions() async throws {
        let suggester = GatedSuggester()
        let store = makeStore(suggester)
        defer { suggester.open() }
        let (session, pane, _) = try backgroundSession(store)
        let sessionTask = try startSessionSuggestion(store, session)
        let sessionCWD = cwd(pane.tabs[0])
        let tab = pane.tabs[1]
        let tabTask = try startTabSuggestion(store, tab)

        _ = store.closeSessionForXPC(id: session.id)

        #expect(!store.sessions.contains { $0.id == session.id })
        await expectSessionCancelled(store, suggester, session, cwd: sessionCWD, sessionTask)
        await expectTabCancelled(store, suggester, tab, tabTask)
    }

    @Test func lastTabCloseCascadeCancelsTheSessionSuggestion() async throws {
        let suggester = GatedSuggester()
        let store = makeStore(suggester)
        defer { suggester.open() }
        let session = try #require(store.addSession())
        store.selectedSessionID = store.sessions[0].id
        let tab = session.tree.allPanes[0].tabs[0]
        let sessionTask = try startSessionSuggestion(store, session)
        let sessionCWD = cwd(tab)

        store.requestCloseTab(id: tab.id)

        #expect(!store.sessions.contains { $0.id == session.id })
        await expectSessionCancelled(store, suggester, session, cwd: sessionCWD, sessionTask)
    }

    @Test func lastPaneCloseCascadeCancelsTheSessionSuggestion() async throws {
        let suggester = GatedSuggester()
        let store = makeStore(suggester)
        defer { suggester.open() }
        let session = try #require(store.addSession())
        store.selectedSessionID = store.sessions[0].id
        let pane = session.tree.allPanes[0]
        let sessionTask = try startSessionSuggestion(store, session)
        let sessionCWD = cwd(pane.tabs[0])

        #expect(store.closePane(id: pane.id) == .closed)

        #expect(!store.sessions.contains { $0.id == session.id })
        await expectSessionCancelled(store, suggester, session, cwd: sessionCWD, sessionTask)
    }

    @Test func windowCloseCancelsEverySuggestionInTheWindowOnly() async throws {
        let suggester = GatedSuggester()
        let store = makeStore(suggester)
        defer { suggester.open() }
        store.terminateHandler = {}
        let w1Session = store.sessions[0]
        let w1Pane = w1Session.tree.allPanes[0]
        let w1Tab = w1Pane.addTab()
        let w1SessionTask = try startSessionSuggestion(store, w1Session)
        let w1TabTask = try startTabSuggestion(store, w1Tab)

        let w2 = store.openWindowRuntime(for: WindowID())
        let w2Session = w2.sessions[0]
        let w2Pane = w2Session.tree.allPanes[0]
        let w2Tab = w2Pane.addTab()
        let w2SessionTask = try startSessionSuggestion(store, w2Session)
        let w2SessionCWD = cwd(w2Pane.tabs[0])
        let w2TabTask = try startTabSuggestion(store, w2Tab)

        w2.tearDownForWindowClose()
        store.removeWindow(id: w2.id)

        await expectSessionCancelled(store, suggester, w2Session, cwd: w2SessionCWD, w2SessionTask)
        await expectTabCancelled(store, suggester, w2Tab, w2TabTask)
        #expect(!w1SessionTask.isCancelled)
        #expect(!w1TabTask.isCancelled)
        #expect(store.nameSuggestionTasks[w1Session.id] != nil)
        #expect(store.tabNameSuggestionTasks[w1Tab.id] != nil)
        suggester.open()
        await awaitTask(w1SessionTask)
        await awaitTask(w1TabTask)
    }

    // MARK: - Late writes and guards

    @Test func inFlightTabSuggestionResumedAfterCloseNeverWritesTheClosedTab() async throws {
        let suggester = GatedSuggester()
        let store = makeStore(suggester)
        defer { suggester.open() }
        let (_, pane, _) = try backgroundSession(store)
        let tab = pane.tabs[1]
        let task = try startTabSuggestion(store, tab)
        guard await suggester.waitUntilStarted(1) else {
            Issue.record("suggestion never started")
            return
        }

        store.requestCloseTab(id: tab.id)
        #expect(task.isCancelled)
        #expect(store.tabNameSuggestionTasks[tab.id] == nil)
        suggester.open()
        await awaitTask(task)

        #expect(tab.aiSuggestedName == nil)
    }

    @Test func releasedTabNeverReceivesALateSuggestion() async throws {
        let suggester = GatedSuggester()
        let store = makeStore(suggester)
        defer { suggester.open() }
        let (_, pane, _) = try backgroundSession(store)
        let tab = pane.tabs[1]
        let task = try startTabSuggestion(store, tab)
        guard await suggester.waitUntilStarted(1) else {
            Issue.record("suggestion never started")
            return
        }

        TerminalHostStore.shared.releaseTerminalView(forTabID: tab.id)
        #expect(!task.isCancelled)
        suggester.open()
        await awaitTask(task)

        #expect(tab.aiSuggestedName == nil)
    }

    @Test func tabSuggestionCancelledBeforeItStartsNeverCallsTheModel() async throws {
        let suggester = GatedSuggester()
        let store = makeStore(suggester)
        defer { suggester.open() }
        let (_, pane, _) = try backgroundSession(store)
        let tab = pane.tabs[1]
        let task = try startTabSuggestion(store, tab)

        store.requestCloseTab(id: tab.id)
        await awaitTask(task)

        #expect(suggester.requestedPaths.isEmpty)
    }

    @Test func sessionSuggestionCancelledBeforeItStartsNeverCallsTheModel() async throws {
        let suggester = GatedSuggester()
        let store = makeStore(suggester)
        defer { suggester.open() }
        let (session, _, _) = try backgroundSession(store)
        let task = try startSessionSuggestion(store, session)

        store.windows[0].requestRemoveSession(id: session.id)
        await awaitTask(task)

        #expect(suggester.requestedPaths.isEmpty)
    }

    // MARK: - Summarization

    private func scheduleRow(_ store: AppStateStore, tabID: UUID, _ title: String) throws -> Task<Void, Never> {
        store.recordCLINotification(tabID: tabID, title: title, body: nil, playSound: false)
        let entry = try #require(store.bellFeed.entries.first { $0.message == title })
        return try #require(store.summarizationTaskForTesting(entryID: entry.id))
    }

    @Test func closingATabCancelsItsRowsSummarization() async throws {
        let summarizer = GatedSummarizer()
        let store = makeStore(GatedSuggester(), summarizer: summarizer)
        defer { summarizer.open() }
        let (_, pane, _) = try backgroundSession(store)
        let closed = try scheduleRow(store, tabID: pane.tabs[0].id, "closed")
        let kept = try scheduleRow(store, tabID: pane.tabs[1].id, "kept")

        store.requestCloseTab(id: pane.tabs[0].id)

        #expect(closed.isCancelled)
        #expect(!kept.isCancelled)
        summarizer.open()
        await awaitTask(closed)
        await awaitTask(kept)
    }

    @Test func visitingATabCancelsItsRowsSummarization() async throws {
        let summarizer = GatedSummarizer()
        let store = makeStore(GatedSuggester(), summarizer: summarizer)
        defer { summarizer.open() }
        let (session, pane, _) = try backgroundSession(store)
        let task = try scheduleRow(store, tabID: pane.activeTabID, "visited")

        _ = store.focusSessionForXPC(id: session.id)

        #expect(!store.bellFeed.entries.contains { $0.message == "visited" }, "precondition: the visit removed the row")
        #expect(task.isCancelled)
        summarizer.open()
        await awaitTask(task)
    }

    @Test func closingASessionOrWindowCancelsItsRowsSummarizations() async throws {
        let summarizer = GatedSummarizer()
        let store = makeStore(GatedSuggester(), summarizer: summarizer)
        defer { summarizer.open() }
        store.terminateHandler = {}
        let (session, pane, _) = try backgroundSession(store)
        let sessionRow = try scheduleRow(store, tabID: pane.tabs[1].id, "session")
        let w2 = store.openWindowRuntime(for: WindowID())
        w2.selectedSessionID = nil
        let windowRow = try scheduleRow(store, tabID: w2.sessions[0].tree.allPanes[0].tabs[0].id, "window")

        store.windows[0].requestRemoveSession(id: session.id)
        w2.tearDownForWindowClose()
        store.removeWindow(id: w2.id)

        #expect(sessionRow.isCancelled)
        #expect(windowRow.isCancelled)
        summarizer.open()
        await awaitTask(sessionRow)
        await awaitTask(windowRow)
    }

    @Test func aLateBellFromAClosedTabAddsNoRowAndSchedulesNoSummary() async throws {
        let summarizer = GatedSummarizer()
        let store = makeStore(GatedSuggester(), summarizer: summarizer)
        defer { summarizer.open() }
        let (_, pane, _) = try backgroundSession(store)
        let closedID = pane.tabs[1].id
        store.requestCloseTab(id: closedID)
        let entriesBefore = store.bellFeed.entries.map(\.id)
        let decisionsBefore = store.bellDecisionHistory.records.count

        store.recordBell(forTabID: closedID, count: 1, at: Date())

        #expect(store.bellFeed.entries.map(\.id) == entriesBefore)
        #expect(store.bellDecisionHistory.records.count == decisionsBefore)
        #expect(!store.bellFeed.entries.contains { $0.tabID == closedID })
    }
}
