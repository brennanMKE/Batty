// ProjectStartupTests.swift

import BattyXPCCore
import Foundation
import Testing
@testable import BattyKit

@MainActor
private final class RecordingSink: StartupInputSink {
    var events: [String] = [] { didSet { resumeWaiters() } }
    var accepts = true
    private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func paste(text: String) -> Bool {
        guard accepts else { return false }
        events.append("paste:\(text)")
        return true
    }

    func pressReturn() -> Bool {
        guard accepts else { return false }
        events.append("return")
        return true
    }

    func waitForEvents(_ count: Int) async {
        if events.count >= count { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }

    private func resumeWaiters() {
        let ready = waiters.filter { events.count >= $0.count }
        waiters.removeAll { events.count >= $0.count }
        for waiter in ready { waiter.continuation.resume() }
    }
}

/// The main queue is FIFO, so once this returns every block queued before it
/// has run: a stand-in for "no deferred delivery is still pending".
@MainActor
private func drainMainQueue() async {
    await withCheckedContinuation { continuation in
        DispatchQueue.main.async { continuation.resume() }
    }
}

@MainActor
private final class Fixture {
    let root: URL
    let projectsFile: URL
    let sinks = SinkBox()
    let clock = TestClock()

    init() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("batty-startup-\(UUID().uuidString)")
        root = base.appendingPathComponent("root")
        projectsFile = base.appendingPathComponent("projects.json")
        for sub in ["", "src"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
    }

    deinit {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }

    func store(projects: Bool = true) -> AppStateStore {
        let store = AppStateStore(
            nameCache: SessionNameCache(fileURL: root.deletingLastPathComponent().appendingPathComponent("cache.json")),
            featureFlags: FeatureFlags(projects: projects),
            projectsFileURL: projectsFile
        )
        let box = sinks
        store.startupInputSinkFactory = { tab in box.sink(for: tab.id) }
        store.startupReadinessClock = clock
        return store
    }

    func project(
        runOnOpen: Bool = true,
        approved: String? = nil,
        tabs: [ProjectTab] = [ProjectTab(title: "build", workingDirectory: ".", startupCommand: "./build.sh")]
    ) -> Project {
        Project(
            name: "Demo", rootPath: root.path, color: .violet,
            layout: ProjectLayout(root: .pane(.terminal(tabs: tabs))),
            runStartupCommandsOnOpen: runOnOpen, approvedCommandsHash: approved)
    }
}

@MainActor
private final class SinkBox {
    private var sinks: [UUID: RecordingSink] = [:]

    var isEmpty: Bool { sinks.values.allSatisfy { $0.events.isEmpty } }

    func sink(for id: UUID) -> RecordingSink {
        if let existing = sinks[id] { return existing }
        let created = RecordingSink()
        sinks[id] = created
        return created
    }
}

@MainActor
private func report(_ path: String, on tab: TabRuntime) {
    tab.terminalDelegate.terminalDidChangeWorkingDirectory(path)
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ProjectStartupDeliveryTests {
    @Test func firstPwdReportDeliversTextThenReturnExactlyOnce() async {
        let tab = TabRuntime()
        let sink = RecordingSink()
        let delivery = tab.armStartupCommand("./build.sh", sink: sink)
        #expect(sink.events.isEmpty)

        report("/work", on: tab)
        #expect(sink.events.isEmpty)
        await delivery.waitUntilFinished()
        #expect(sink.events == ["paste:./build.sh", "return"])

        report("/work/src", on: tab)
        await drainMainQueue()
        #expect(sink.events == ["paste:./build.sh", "return"])
    }

    @Test func deliveryIsDeferredOutOfTheCallback() async {
        let tab = TabRuntime()
        let sink = RecordingSink()
        let delivery = tab.armStartupCommand("x", sink: sink)
        report("/work", on: tab)
        #expect(!delivery.isFinished)
        #expect(sink.events.isEmpty)
        await delivery.waitUntilFinished()
        #expect(delivery.isFinished)
    }

    @Test func reportThatArrivedBeforeArmingStillDeliversOnce() async {
        let tab = TabRuntime()
        let sink = RecordingSink()
        report("/work", on: tab)

        let delivery = tab.armStartupCommand("claude", sink: sink)
        await delivery.waitUntilFinished()
        #expect(sink.events == ["paste:claude", "return"])

        report("/elsewhere", on: tab)
        await drainMainQueue()
        #expect(sink.events == ["paste:claude", "return"])
    }

    @Test func composesWithAutoNamingWhicheverIsInstalledFirst() async {
        let store = AppStateStore(featureFlags: FeatureFlags(projects: false))

        let armedFirst = TabRuntime()
        let firstSink = RecordingSink()
        let first = armedFirst.armStartupCommand("a", sink: firstSink)
        store.wireWorkingDirectoryReporting(for: armedFirst)
        report("/one", on: armedFirst)
        await first.waitUntilFinished()
        #expect(firstSink.events == ["paste:a", "return"])
        #expect(armedFirst.workingDirectory == "/one")

        let wiredFirst = TabRuntime()
        let secondSink = RecordingSink()
        store.wireWorkingDirectoryReporting(for: wiredFirst)
        let second = wiredFirst.armStartupCommand("b", sink: secondSink)
        report("/two", on: wiredFirst)
        await second.waitUntilFinished()
        #expect(secondSink.events == ["paste:b", "return"])
        #expect(wiredFirst.workingDirectory == "/two")

        store.wireWorkingDirectoryReporting(for: wiredFirst)
        report("/three", on: wiredFirst)
        await drainMainQueue()
        #expect(secondSink.events == ["paste:b", "return"])
        #expect(wiredFirst.workingDirectory == "/three")
    }

    @Test func multiLineCommandSendsEachLineWithItsOwnReturn() async {
        let tab = TabRuntime()
        let sink = RecordingSink()
        let delivery = tab.armStartupCommand("cd src\n\n  \nmake\r\nls", sink: sink)
        report("/work", on: tab)
        await delivery.waitUntilFinished()
        #expect(sink.events == ["paste:cd src", "return", "paste:make", "return", "paste:ls", "return"])
    }

    @Test func controlAndFormatCharactersAreDroppedFromTheText() {
        #expect(StartupCommandDelivery.lines(from: "echo\u{1B}[201~ hi\tthere\u{7}") == ["echo[201~ hi\tthere"])
        #expect(StartupCommandDelivery.lines(from: "ls \u{202E}gnp.txt\u{200B}\u{2066}") == ["ls gnp.txt"])
    }

    @Test func refusedInputStopsAndDoesNotRetry() async {
        let tab = TabRuntime()
        let sink = RecordingSink()
        sink.accepts = false
        let delivery = tab.armStartupCommand("a\nb", sink: sink)
        report("/work", on: tab)
        await delivery.waitUntilFinished()
        sink.accepts = true
        report("/work/src", on: tab)
        await drainMainQueue()
        #expect(sink.events.isEmpty)
    }
}

@MainActor
struct ProjectStartupHashTests {
    private func project(_ tabs: [ProjectTab]) -> Project {
        Project(name: "P", rootPath: "/tmp/p", layout: ProjectLayout(root: .pane(.terminal(tabs: tabs))))
    }

    @Test func digestIsStableAcrossLaunches() {
        let p = project([
            ProjectTab(title: "build", workingDirectory: ".", startupCommand: "./build.sh"),
            ProjectTab(title: nil, workingDirectory: "src", startupCommand: "claude"),
        ])
        #expect(p.startupCommandsHash == "c7328cdec1f2d03bd616c62de28795e8346937d970bb97cc617c2be5122b30cc")
    }

    @Test func commandDirectoryAndOrderChangeTheHash() {
        let a = ProjectTab(title: "a", workingDirectory: ".", startupCommand: "make")
        let b = ProjectTab(title: "b", workingDirectory: "src", startupCommand: "claude")
        let base = project([a, b]).startupCommandsHash

        var editedCommand = a
        editedCommand.startupCommand = "make all"
        #expect(project([editedCommand, b]).startupCommandsHash != base)

        var editedDirectory = a
        editedDirectory.workingDirectory = "src"
        #expect(project([editedDirectory, b]).startupCommandsHash != base)

        #expect(project([b, a]).startupCommandsHash != base)
    }

    @Test func titleChangeAndBlankCommandsDoNotChangeTheHash() {
        let a = ProjectTab(title: "a", workingDirectory: ".", startupCommand: "make")
        let base = project([a]).startupCommandsHash

        var retitled = a
        retitled.title = "renamed"
        #expect(project([retitled]).startupCommandsHash == base)

        let blank = ProjectTab(title: "x", workingDirectory: "src", startupCommand: "  ")
        #expect(project([a, blank]).startupCommandsHash == base)
    }

    @Test func changingTheRootChangesTheHash() {
        let tabs = [ProjectTab(workingDirectory: ".", startupCommand: "./build.sh")]
        let layout = ProjectLayout(root: .pane(.terminal(tabs: tabs)))
        let here = Project(name: "P", rootPath: "/tmp/p", layout: layout)
        let there = Project(name: "P", rootPath: "/tmp/q", layout: layout)
        #expect(here.startupCommandsHash != there.startupCommandsHash)
    }

    @Test func fieldBoundariesAreUnambiguous() {
        let one = project([ProjectTab(workingDirectory: "a", startupCommand: "bc")])
        let two = project([ProjectTab(workingDirectory: "ab", startupCommand: "c")])
        #expect(one.startupCommandsHash != two.startupCommandsHash)
    }
}

@MainActor
struct ProjectStartupTrustLogicTests {
    private func project(run: Bool, approved: String?, command: String? = "make") -> Project {
        Project(
            name: "P", rootPath: "/tmp/p",
            layout: ProjectLayout(root: .pane(.terminal(tabs: [ProjectTab(startupCommand: command)]))),
            runStartupCommandsOnOpen: run, approvedCommandsHash: approved)
    }

    @Test func toggleOffRunsNothingAndNeverPrompts() {
        let p = project(run: false, approved: nil)
        #expect(ProjectStartupTrust.decide(p) == .skip)
    }

    @Test func noCommandsNeverPrompts() {
        #expect(ProjectStartupTrust.decide(project(run: true, approved: nil, command: " ")) == .skip)
    }

    @Test func matchingHashRunsWithoutPrompt() {
        var p = project(run: true, approved: nil)
        p.approvedCommandsHash = p.startupCommandsHash
        #expect(ProjectStartupTrust.decide(p) == .runWithoutPrompt)
    }

    @Test func missingOrDifferentHashPrompts() {
        #expect(ProjectStartupTrust.decide(project(run: true, approved: nil)) == .prompt)
        #expect(ProjectStartupTrust.decide(project(run: true, approved: "stale")) == .prompt)
    }

    @Test func choicesMapToOutcomes() {
        let p = project(run: true, approved: nil)
        #expect(ProjectStartupTrust.outcome(for: .openWithoutRunning, project: p)
            == ProjectStartupOutcome(runCommands: false, hashToStore: nil))
        #expect(ProjectStartupTrust.outcome(for: .run(rememberApproval: true), project: p)
            == ProjectStartupOutcome(runCommands: true, hashToStore: p.startupCommandsHash))
        #expect(ProjectStartupTrust.outcome(for: .run(rememberApproval: false), project: p)
            == ProjectStartupOutcome(runCommands: true, hashToStore: nil))
    }

    @Test func rowsNameThePaneAndTab() {
        let p = Project(
            name: "P", rootPath: "/tmp/p",
            layout: .preset(.horizontalSplit))
        var edited = p
        edited.layout = ProjectLayout(root: .split(direction: .horizontal, children: [
            .pane(.terminal(tabs: [ProjectTab(title: "build", startupCommand: "./build.sh")])),
            .pane(.terminal(tabs: [ProjectTab(), ProjectTab(title: " ", startupCommand: "claude")])),
        ]))
        let rows = ProjectStartupTrust.rows(for: edited)
        #expect(rows.map(\.label) == ["Pane 1 \u{00B7} build", "Pane 2 \u{00B7} Tab 2"])
        #expect(rows.map(\.command) == ["./build.sh", "claude"])
    }

    @Test func rowsShowTheTextThatWillRun() {
        let p = Project(
            name: "P", rootPath: "/tmp/p",
            layout: ProjectLayout(root: .pane(.terminal(tabs: [ProjectTab(startupCommand: "ls \u{202E}gnp\nmake")]))))
        #expect(ProjectStartupTrust.rows(for: p).map(\.command) == ["ls gnp\nmake"])
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ProjectStartupOpenTests {
    private func firstTab(of session: SessionRuntime) -> TabRuntime {
        session.tree.allPanes[0].tabs[0]
    }

    @Test func toggleOffOpensWithoutSheetOrCommands() async throws {
        let fixture = try Fixture()
        let store = fixture.store()
        let project = fixture.project(runOnOpen: false)
        try store.projectStore?.upsert(project)

        var result: Result<AppStateStore.ProjectOpenResult, Error>?
        store.requestOpenProject(id: project.id, completion: { result = $0 })

        let session = try #require(try result?.get().session)
        #expect(store.windows.allSatisfy { $0.pendingStartupTrusts.isEmpty })
        let tab = firstTab(of: session)
        report("/work", on: tab)
        await drainMainQueue()
        #expect(fixture.sinks.sink(for: tab.id).events.isEmpty)
    }

    @Test func matchingHashRunsWithoutSheet() async throws {
        let fixture = try Fixture()
        let store = fixture.store()
        var project = fixture.project()
        project.approvedCommandsHash = project.startupCommandsHash
        try store.projectStore?.upsert(project)

        var result: Result<AppStateStore.ProjectOpenResult, Error>?
        store.requestOpenProject(id: project.id, completion: { result = $0 })

        let session = try #require(try result?.get().session)
        #expect(store.windows.allSatisfy { $0.pendingStartupTrusts.isEmpty })
        let tab = firstTab(of: session)
        report("/work", on: tab)
        await fixture.sinks.sink(for: tab.id).waitForEvents(2)
        #expect(fixture.sinks.sink(for: tab.id).events == ["paste:./build.sh", "return"])
    }

    @Test func newCommandsAskFirstAndCreateNothingUntilAnswered() async throws {
        let fixture = try Fixture()
        let store = fixture.store()
        let project = fixture.project()
        try store.projectStore?.upsert(project)
        let sessionsBefore = store.windows.flatMap(\.sessions).count

        var result: Result<AppStateStore.ProjectOpenResult, Error>?
        store.requestOpenProject(id: project.id, completion: { result = $0 })

        #expect(result == nil)
        #expect(store.windows.flatMap(\.sessions).count == sessionsBefore)
        let window = try #require(store.defaultTargetWindow())
        let request = try #require(window.pendingStartupTrusts.first)
        #expect(request.projectName == "Demo")
        #expect(request.rows.map(\.command) == ["./build.sh"])
    }

    @Test func runCommandsWithRememberStoresTheHashAndRuns() async throws {
        let fixture = try Fixture()
        let store = fixture.store()
        let project = fixture.project()
        try store.projectStore?.upsert(project)
        var result: Result<AppStateStore.ProjectOpenResult, Error>?
        store.requestOpenProject(id: project.id, completion: { result = $0 })
        let window = try #require(store.defaultTargetWindow())
        let request = try #require(window.pendingStartupTrusts.first)

        store.resolveStartupTrust(requestID: request.id, choice: .run(rememberApproval: true))

        let session = try #require(try result?.get().session)
        #expect(window.pendingStartupTrusts.isEmpty)
        #expect(store.projectStore?.project(id: project.id)?.approvedCommandsHash == project.startupCommandsHash)
        let tab = firstTab(of: session)
        report("/work", on: tab)
        await fixture.sinks.sink(for: tab.id).waitForEvents(2)
        #expect(fixture.sinks.sink(for: tab.id).events == ["paste:./build.sh", "return"])

        var again: Result<AppStateStore.ProjectOpenResult, Error>?
        store.requestOpenProject(id: project.id, mode: .openNew, completion: { again = $0 })
        _ = try #require(try again?.get())
        #expect(window.pendingStartupTrusts.isEmpty)
    }

    @Test func runCommandsWithoutRememberLeavesTheHashAlone() async throws {
        let fixture = try Fixture()
        let store = fixture.store()
        let project = fixture.project()
        try store.projectStore?.upsert(project)
        var result: Result<AppStateStore.ProjectOpenResult, Error>?
        store.requestOpenProject(id: project.id, completion: { result = $0 })
        let window = try #require(store.defaultTargetWindow())

        store.resolveStartupTrust(
            requestID: try #require(window.pendingStartupTrusts.first).id,
            choice: .run(rememberApproval: false))

        let session = try #require(try result?.get().session)
        #expect(store.projectStore?.project(id: project.id)?.approvedCommandsHash == nil)
        let tab = firstTab(of: session)
        report("/work", on: tab)
        await fixture.sinks.sink(for: tab.id).waitForEvents(2)
        #expect(fixture.sinks.sink(for: tab.id).events == ["paste:./build.sh", "return"])
    }

    @Test func openWithoutRunningOpensButRunsNothingAndKeepsTheHash() async throws {
        let fixture = try Fixture()
        let store = fixture.store()
        let project = fixture.project(approved: "stale")
        try store.projectStore?.upsert(project)
        var result: Result<AppStateStore.ProjectOpenResult, Error>?
        store.requestOpenProject(id: project.id, completion: { result = $0 })
        let window = try #require(store.defaultTargetWindow())

        store.resolveStartupTrust(
            requestID: try #require(window.pendingStartupTrusts.first).id,
            choice: .openWithoutRunning)

        let session = try #require(try result?.get().session)
        #expect(store.projectStore?.project(id: project.id)?.approvedCommandsHash == "stale")
        let tab = firstTab(of: session)
        report("/work", on: tab)
        await drainMainQueue()
        #expect(fixture.sinks.sink(for: tab.id).events.isEmpty)
    }

    @Test func dismissingTheSheetCancelsTheOpen() async throws {
        let fixture = try Fixture()
        let store = fixture.store()
        let project = fixture.project()
        try store.projectStore?.upsert(project)
        let sessionsBefore = store.windows.flatMap(\.sessions).count
        var result: Result<AppStateStore.ProjectOpenResult, Error>?
        store.requestOpenProject(id: project.id, completion: { result = $0 })
        let window = try #require(store.defaultTargetWindow())

        store.cancelStartupTrust(requestID: try #require(window.pendingStartupTrusts.first).id)

        #expect(throws: ProjectOpenError.cancelled) { try result?.get() }
        #expect(window.pendingStartupTrusts.isEmpty)
        #expect(store.windows.flatMap(\.sessions).count == sessionsBefore)
    }

    @Test func focusingAnOpenProjectNeverPromptsOrRuns() async throws {
        let fixture = try Fixture()
        let store = fixture.store()
        let project = fixture.project(runOnOpen: false)
        try store.projectStore?.upsert(project)
        _ = try store.openProject(id: project.id)

        var edited = project
        edited.runStartupCommandsOnOpen = true
        try store.projectStore?.upsert(edited)
        var result: Result<AppStateStore.ProjectOpenResult, Error>?
        store.requestOpenProject(id: project.id, completion: { result = $0 })

        #expect(try result?.get().wasCreated == false)
        #expect(store.windows.allSatisfy { $0.pendingStartupTrusts.isEmpty })
    }

    @Test func flagOffIsInert() async throws {
        let fixture = try Fixture()
        let store = fixture.store(projects: false)
        var result: Result<AppStateStore.ProjectOpenResult, Error>?
        store.requestOpenProject(id: UUID(), completion: { result = $0 })

        #expect(throws: ProjectOpenError.featureDisabled) { try result?.get() }
        #expect(store.windows.allSatisfy { $0.pendingStartupTrusts.isEmpty })
        #expect(!FileManager.default.fileExists(atPath: fixture.projectsFile.path))
    }

    @Test func commandsLandOnTheirOwnPaneAndTab() async throws {
        let fixture = try Fixture()
        let store = fixture.store()
        var project = Project(
            name: "Two", rootPath: fixture.root.path,
            layout: ProjectLayout(root: .split(direction: .horizontal, children: [
                .pane(.terminal(tabs: [ProjectTab(startupCommand: "one")])),
                .pane(.terminal(tabs: [ProjectTab(), ProjectTab(workingDirectory: "src", startupCommand: "two")])),
            ])),
            runStartupCommandsOnOpen: true)
        project.approvedCommandsHash = project.startupCommandsHash
        try store.projectStore?.upsert(project)

        var result: Result<AppStateStore.ProjectOpenResult, Error>?
        store.requestOpenProject(id: project.id, completion: { result = $0 })
        let panes = try #require(try result?.get().session).tree.allPanes
        for pane in panes { for tab in pane.tabs { report("/work", on: tab) } }

        await fixture.sinks.sink(for: panes[0].tabs[0].id).waitForEvents(2)

        #expect(fixture.sinks.sink(for: panes[0].tabs[0].id).events == ["paste:one", "return"])
        await drainMainQueue()
        #expect(fixture.sinks.sink(for: panes[1].tabs[0].id).events.isEmpty)
        await fixture.sinks.sink(for: panes[1].tabs[1].id).waitForEvents(2)
        #expect(fixture.sinks.sink(for: panes[1].tabs[1].id).events == ["paste:two", "return"])
    }

    @Test func removingTheWindowCancelsItsPendingRequest() async throws {
        let fixture = try Fixture()
        let store = fixture.store()
        let project = fixture.project()
        try store.projectStore?.upsert(project)
        var result: Result<AppStateStore.ProjectOpenResult, Error>?
        store.requestOpenProject(id: project.id, completion: { result = $0 })
        let window = try #require(store.defaultTargetWindow())
        #expect(window.pendingStartupTrusts.count == 1)

        store.removeWindow(id: window.id)

        #expect(throws: ProjectOpenError.cancelled) { try result?.get() }
        #expect(window.pendingStartupTrusts.isEmpty)
        #expect(store.pendingStartupOpens.isEmpty)
        #expect(store.openProjectIDs.isEmpty)
    }

    @Test func editingTheCommandsWhileTheSheetIsOpenAsksAgain() async throws {
        let fixture = try Fixture()
        let store = fixture.store()
        let project = fixture.project()
        try store.projectStore?.upsert(project)
        var results: [Result<AppStateStore.ProjectOpenResult, Error>] = []
        store.requestOpenProject(id: project.id, completion: { results.append($0) })
        let window = try #require(store.defaultTargetWindow())
        let original = try #require(window.pendingStartupTrusts.first)

        var edited = project
        edited.layout = ProjectLayout(root: .pane(.terminal(tabs: [
            ProjectTab(title: "build", workingDirectory: ".", startupCommand: "rm -rf build"),
        ])))
        try store.projectStore?.upsert(edited)
        store.resolveStartupTrust(requestID: original.id, choice: .run(rememberApproval: true))

        #expect(results.isEmpty)
        let renewed = try #require(window.pendingStartupTrusts.first)
        #expect(window.pendingStartupTrusts.count == 1)
        #expect(renewed.id != original.id)
        #expect(renewed.commandsHash == edited.startupCommandsHash)
        #expect(renewed.commandsHash != original.commandsHash)
        #expect(renewed.rows.map(\.command) == ["rm -rf build"])
        #expect(store.projectStore?.project(id: project.id)?.approvedCommandsHash == nil)
        #expect(store.openProjectIDs.isEmpty)
        for pane in window.sessions.flatMap({ $0.tree.allPanes }) {
            for tab in pane.tabs { report("/work", on: tab) }
        }
        await drainMainQueue()
        #expect(fixture.sinks.isEmpty)
    }

    @Test func turningTheRunToggleOffWhileTheSheetIsOpenRunsNothing() async throws {
        let fixture = try Fixture()
        let store = fixture.store()
        let project = fixture.project()
        try store.projectStore?.upsert(project)
        var results: [Result<AppStateStore.ProjectOpenResult, Error>] = []
        store.requestOpenProject(id: project.id, completion: { results.append($0) })
        let window = try #require(store.defaultTargetWindow())
        let original = try #require(window.pendingStartupTrusts.first)

        var edited = project
        edited.runStartupCommandsOnOpen = false
        try store.projectStore?.upsert(edited)
        store.resolveStartupTrust(requestID: original.id, choice: .run(rememberApproval: true))

        let session = try #require(try results.first?.get().session)
        #expect(window.pendingStartupTrusts.isEmpty)
        report("/work", on: session.tree.allPanes[0].tabs[0])
        await drainMainQueue()
        #expect(fixture.sinks.isEmpty)
    }

    @Test func answeringTheSameRequestTwiceCompletesOnce() async throws {
        let fixture = try Fixture()
        let store = fixture.store()
        let project = fixture.project()
        try store.projectStore?.upsert(project)
        var results: [Result<AppStateStore.ProjectOpenResult, Error>] = []
        store.requestOpenProject(id: project.id, completion: { results.append($0) })
        let window = try #require(store.defaultTargetWindow())
        let request = try #require(window.pendingStartupTrusts.first)

        store.resolveStartupTrust(requestID: request.id, choice: .run(rememberApproval: false))
        let sessionsAfterFirst = store.windows.flatMap(\.sessions).count
        store.resolveStartupTrust(requestID: request.id, choice: .run(rememberApproval: false))
        store.cancelStartupTrust(requestID: request.id)

        #expect(results.count == 1)
        #expect(store.windows.flatMap(\.sessions).count == sessionsAfterFirst)
    }
}

@MainActor
private func attach(_ tab: TabRuntime) {
    tab.terminalDelegate.surfaceDidAttach()
}

/// Advances `clock` past the readiness deadline and returns once the
/// deadline Task has finished running.
@MainActor
private func passDeadline(of tab: TabRuntime, on clock: TestClock) async {
    let task = tab.terminalDelegate.readinessDeadlineTask
    await clock.advance(by: StartupCommandReadiness.deadline)
    await task?.value
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ProjectStartupReadinessTests {
    @Test func reportBeforeTheDeadlineDeliversOnceAndLeavesNothingScheduled() async {
        let clock = TestClock()
        let tab = TabRuntime()
        let sink = RecordingSink()
        let delivery = tab.armStartupCommand("./build.sh", sink: sink, clock: clock)
        attach(tab)
        await clock.waitForSleepers(1)

        report("/work", on: tab)
        #expect(clock.pendingCount == 0)
        await delivery.waitUntilFinished()
        #expect(sink.events == ["paste:./build.sh", "return"])
        #expect(tab.startupCommandWaiting == nil)

        report("/work/src", on: tab)
        await drainMainQueue()
        #expect(sink.events == ["paste:./build.sh", "return"])
    }

    @Test func deadlineWithoutAReportTypesNothingAndEntersTheWaitingState() async {
        let clock = TestClock()
        let tab = TabRuntime()
        let sink = RecordingSink()
        let delivery = tab.armStartupCommand("cd src\nmake", sink: sink, clock: clock)
        attach(tab)
        await clock.waitForSleepers(1)
        #expect(tab.startupCommandWaiting == nil)

        await passDeadline(of: tab, on: clock)

        #expect(tab.startupCommandWaiting == StartupCommandWaiting(command: "cd src\nmake"))
        #expect(sink.events.isEmpty)
        #expect(!delivery.isFinished)
        #expect(clock.pendingCount == 0)
    }

    @Test func lateReportDeliversOnceAndClearsTheWaitingState() async {
        let clock = TestClock()
        let tab = TabRuntime()
        let sink = RecordingSink()
        let delivery = tab.armStartupCommand("claude", sink: sink, clock: clock)
        attach(tab)
        await clock.waitForSleepers(1)
        await passDeadline(of: tab, on: clock)
        #expect(tab.startupCommandWaiting != nil)

        report("/work", on: tab)
        #expect(tab.startupCommandWaiting == nil)
        await delivery.waitUntilFinished()
        #expect(sink.events == ["paste:claude", "return"])

        report("/work/src", on: tab)
        await drainMainQueue()
        #expect(sink.events == ["paste:claude", "return"])
    }

    @Test func runNowDeliversOnceAndALaterReportDeliversNothing() async throws {
        let clock = TestClock()
        let tab = TabRuntime()
        let sink = RecordingSink()
        let delivery = tab.armStartupCommand("claude", sink: sink, clock: clock)
        attach(tab)
        await clock.waitForSleepers(1)
        await passDeadline(of: tab, on: clock)

        tab.runWaitingStartupCommand()
        #expect(tab.startupCommandWaiting == nil)
        await delivery.waitUntilFinished()
        #expect(sink.events == ["paste:claude", "return"])

        report("/work", on: tab)
        tab.runWaitingStartupCommand()
        await drainMainQueue()
        #expect(sink.events == ["paste:claude", "return"])
    }

    @Test func dismissTypesNothingClearsTheStateAndALaterReportDeliversNothing() async {
        let clock = TestClock()
        let tab = TabRuntime()
        let sink = RecordingSink()
        tab.armStartupCommand("claude", sink: sink, clock: clock)
        attach(tab)
        await clock.waitForSleepers(1)
        await passDeadline(of: tab, on: clock)

        tab.dismissWaitingStartupCommand()
        #expect(tab.startupCommandWaiting == nil)

        report("/work", on: tab)
        tab.runWaitingStartupCommand()
        await drainMainQueue()
        #expect(sink.events.isEmpty)
        #expect(clock.pendingCount == 0)
    }

    @Test func shellClosingBeforeAnyReportDisarmsWithoutAWaitingState() async {
        let clock = TestClock()
        let tab = TabRuntime()
        let sink = RecordingSink()
        tab.armStartupCommand("claude", sink: sink, clock: clock)
        attach(tab)
        await clock.waitForSleepers(1)

        tab.terminalDelegate.terminalDidClose(processAlive: false)

        #expect(clock.pendingCount == 0)
        #expect(tab.startupCommandWaiting == nil)
        report("/work", on: tab)
        await drainMainQueue()
        #expect(sink.events.isEmpty)
    }

    @Test func shellClosingWhileWaitingClearsTheState() async {
        let clock = TestClock()
        let tab = TabRuntime()
        let sink = RecordingSink()
        tab.armStartupCommand("claude", sink: sink, clock: clock)
        attach(tab)
        await clock.waitForSleepers(1)
        await passDeadline(of: tab, on: clock)
        #expect(tab.startupCommandWaiting != nil)

        tab.terminalDelegate.terminalDidClose(processAlive: false)

        #expect(tab.startupCommandWaiting == nil)
        #expect(sink.events.isEmpty)
    }

    @Test func awaitingADismissedOrClosedDeliveryReturns() async {
        let clock = TestClock()
        let dismissedTab = TabRuntime()
        let dismissedSink = RecordingSink()
        let dismissed = dismissedTab.armStartupCommand("a", sink: dismissedSink, clock: clock)
        attach(dismissedTab)
        await clock.waitForSleepers(1)
        await passDeadline(of: dismissedTab, on: clock)
        dismissedTab.dismissWaitingStartupCommand()
        await dismissed.waitUntilFinished()

        let closedTab = TabRuntime()
        let closed = closedTab.armStartupCommand("b", sink: RecordingSink(), clock: clock)
        closedTab.terminalDelegate.terminalDidClose(processAlive: false)
        await closed.waitUntilFinished()
        #expect(dismissedSink.events.isEmpty)
    }

    @Test func tabTeardownCancelsTheDeadline() async {
        let clock = TestClock()
        var tab: TabRuntime? = TabRuntime()
        tab?.armStartupCommand("a", sink: RecordingSink(), clock: clock)
        tab.map(attach)
        await clock.waitForSleepers(1)
        tab = nil
        #expect(clock.pendingCount == 0)
    }

    @Test func rearmingReplacesTheRunningDeadlineAndAbandonsTheOldDelivery() async {
        let clock = TestClock()
        let tab = TabRuntime()
        let firstSink = RecordingSink()
        let secondSink = RecordingSink()
        let first = tab.armStartupCommand("first", sink: firstSink, clock: clock)
        attach(tab)
        await clock.waitForSleepers(1)

        let second = tab.armStartupCommand("second", sink: secondSink, clock: clock)
        await first.waitUntilFinished()
        await clock.waitForSleepers(1)
        #expect(clock.pendingCount == 1)

        await passDeadline(of: tab, on: clock)
        #expect(tab.startupCommandWaiting == StartupCommandWaiting(command: "second"))
        report("/work", on: tab)
        await second.waitUntilFinished()
        #expect(firstSink.events.isEmpty)
        #expect(secondSink.events == ["paste:second", "return"])
    }

    @Test func deadlineStartsAtSurfaceAttachNotAtArming() async {
        let clock = TestClock()
        let tab = TabRuntime()
        let sink = RecordingSink()
        tab.armStartupCommand("claude", sink: sink, clock: clock)
        #expect(clock.pendingCount == 0)

        #expect(await clock.advance(by: StartupCommandReadiness.deadline * 3) == 0)
        #expect(tab.startupCommandWaiting == nil)

        attach(tab)
        await clock.waitForSleepers(1)
        #expect(tab.startupCommandWaiting == nil)
        await passDeadline(of: tab, on: clock)
        #expect(tab.startupCommandWaiting != nil)
    }

    @Test func armingAfterTheSurfaceAttachedStartsTheDeadline() async {
        let clock = TestClock()
        let tab = TabRuntime()
        attach(tab)
        tab.armStartupCommand("claude", sink: RecordingSink(), clock: clock)
        await clock.waitForSleepers(1)
        await passDeadline(of: tab, on: clock)
        #expect(tab.startupCommandWaiting != nil)
    }

    @Test func attachingAgainDoesNotRestartARunningDeadline() async {
        let clock = TestClock()
        let tab = TabRuntime()
        tab.armStartupCommand("claude", sink: RecordingSink(), clock: clock)
        attach(tab)
        await clock.waitForSleepers(1)
        attach(tab)
        #expect(clock.pendingCount == 1)
    }

    @Test func aTabArmedWithNoCommandNeverSchedulesADeadline() async {
        let clock = TestClock()
        let tab = TabRuntime()
        let sink = RecordingSink()
        let delivery = tab.armStartupCommand("  \n\t", sink: sink, clock: clock)
        attach(tab)
        await delivery.waitUntilFinished()
        #expect(clock.pendingCount == 0)
        #expect(sink.events.isEmpty)
        #expect(tab.startupCommandWaiting == nil)
    }

    @Test func reportThatArrivedBeforeArmingNeverSchedulesADeadline() async {
        let clock = TestClock()
        let tab = TabRuntime()
        let sink = RecordingSink()
        report("/work", on: tab)
        attach(tab)
        let delivery = tab.armStartupCommand("claude", sink: sink, clock: clock)
        await delivery.waitUntilFinished()
        #expect(clock.pendingCount == 0)
        #expect(sink.events == ["paste:claude", "return"])
    }

    @Test func autoNamingStillReceivesEveryReportAcrossTheWaitingState() async {
        let clock = TestClock()
        let tab = TabRuntime()
        var reported: [String] = []
        tab.terminalDelegate.onWorkingDirectoryChange = { reported.append($0) }
        let delivery = tab.armStartupCommand("claude", sink: RecordingSink(), clock: clock)
        attach(tab)
        await clock.waitForSleepers(1)
        await passDeadline(of: tab, on: clock)
        report("/a", on: tab)
        report("/b", on: tab)
        await delivery.waitUntilFinished()
        #expect(reported == ["/a", "/b"])
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ProjectStartupReadinessOpenTests {
    @Test func openingWithCommandsSchedulesTheDeadlineOnTheStoresClock() async throws {
        let fixture = try Fixture()
        let store = fixture.store()
        var project = fixture.project()
        project.approvedCommandsHash = project.startupCommandsHash
        try store.projectStore?.upsert(project)
        var result: Result<AppStateStore.ProjectOpenResult, Error>?
        store.requestOpenProject(id: project.id, completion: { result = $0 })
        let session = try #require(try result?.get().session)
        let tab = session.tree.allPanes[0].tabs[0]
        #expect(fixture.clock.pendingCount == 0)

        attach(tab)
        await fixture.clock.waitForSleepers(1)
        await passDeadline(of: tab, on: fixture.clock)

        #expect(tab.startupCommandWaiting == StartupCommandWaiting(command: "./build.sh"))
        #expect(fixture.sinks.isEmpty)
    }

    @Test func openingWithoutRunningCommandsNeverSchedulesADeadline() async throws {
        let fixture = try Fixture()
        let store = fixture.store()
        let project = fixture.project(runOnOpen: false)
        try store.projectStore?.upsert(project)
        var result: Result<AppStateStore.ProjectOpenResult, Error>?
        store.requestOpenProject(id: project.id, completion: { result = $0 })
        let session = try #require(try result?.get().session)
        let tab = session.tree.allPanes[0].tabs[0]

        attach(tab)
        await drainMainQueue()
        #expect(fixture.clock.pendingCount == 0)
        #expect(tab.startupCommandWaiting == nil)
    }

    @Test func openWithoutRunningChoiceNeverSchedulesADeadline() async throws {
        let fixture = try Fixture()
        let store = fixture.store()
        let project = fixture.project()
        try store.projectStore?.upsert(project)
        var result: Result<AppStateStore.ProjectOpenResult, Error>?
        store.requestOpenProject(id: project.id, completion: { result = $0 })
        let window = try #require(store.defaultTargetWindow())
        let request = try #require(window.pendingStartupTrusts.first)
        store.resolveStartupTrust(requestID: request.id, choice: .openWithoutRunning)
        let session = try #require(try result?.get().session)
        let tab = session.tree.allPanes[0].tabs[0]

        attach(tab)
        await drainMainQueue()
        #expect(fixture.clock.pendingCount == 0)
        #expect(tab.startupCommandWaiting == nil)
    }
}
