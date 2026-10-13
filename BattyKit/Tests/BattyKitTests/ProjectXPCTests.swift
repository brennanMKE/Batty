// ProjectXPCTests.swift

import AppKit
import BattyXPCCore
import Foundation
import Testing
@testable import BattyKit

@MainActor
private final class Fixture {
    let base: URL
    let root: URL
    let projectsFile: URL

    init() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("batty-projectxpc-\(UUID().uuidString)")
        root = base.appendingPathComponent("root")
        projectsFile = base.appendingPathComponent("projects.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: base)
    }

    func store(projects: Bool = true) -> AppStateStore {
        AppStateStore(
            nameCache: SessionNameCache(fileURL: base.appendingPathComponent("cache.json")),
            featureFlags: FeatureFlags(projects: projects),
            projectsFileURL: projectsFile
        )
    }

    func project(_ name: String, command: String? = nil, panes: Int = 1) -> Project {
        let leaf = ProjectLayoutNode.pane(.terminal(tabs: [ProjectTab(startupCommand: command)]))
        let node: ProjectLayoutNode = panes == 1 ? leaf : .split(direction: .horizontal, children: Array(repeating: leaf, count: panes))
        return Project(name: name, rootPath: root.path, color: .violet, layout: ProjectLayout(root: node),
                       runStartupCommandsOnOpen: command != nil)
    }
}

@MainActor
private final class ActivationLog {
    var count = 0
}

@MainActor
private final class TargetLog {
    var ids: [WindowID] = []
}

@MainActor
private final class EventRecorder {
    private(set) var payloads: [WatchEventPayload] = []
    private var id: UUID?

    init() {
        id = AppEventWatcher.shared.subscribe(events: ["session_created", "session_focused"]) { [weak self] payload in
            MainActor.assumeIsolated { self?.payloads.append(payload) }
        }
    }

    func stop() {
        if let id { AppEventWatcher.shared.unsubscribe(id: id) }
        id = nil
    }
}

@MainActor
private func perform(_ service: AppXPCService, verb: String, payload: Data? = nil) async throws -> XPCResponse {
    let requestData = try JSONEncoder().encode(XPCRequest(verb: verb, payload: payload))
    let responseData: Data = await withCheckedContinuation { continuation in
        service.perform(requestData) { continuation.resume(returning: $0) }
    }
    return try JSONDecoder().decode(XPCResponse.self, from: responseData)
}

@MainActor
private func open(_ service: AppXPCService, _ name: String, openNew: Bool = false) async throws -> XPCResponse {
    try await perform(service, verb: XPCVerb.projectOpen, payload: JSONEncoder().encode(ProjectOpenRequest(name: name, openNew: openNew)))
}

private func reply(_ response: XPCResponse) throws -> ProjectOpenReply {
    try JSONDecoder().decode(ProjectOpenReply.self, from: try #require(response.payload))
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ProjectXPCTests {
    // MARK: - Flag off

    @Test func flagOffRefusesBothVerbsAsUnknownAndNeverTouchesTheStore() async throws {
        let fixture = try Fixture()
        let store = fixture.store(projects: false)
        let service = AppXPCService(store: { store }, clock: TestClock())
        let sessionsBefore = store.windows.flatMap(\.sessions).count

        let list = try await perform(service, verb: XPCVerb.projectList)
        #expect(list.ok == false)
        #expect(list.error == "unknown verb: projectList")
        #expect(list.payload == nil)

        let open = try await open(service, "Anything")
        #expect(open.ok == false)
        #expect(open.error == "unknown verb: projectOpen")

        #expect(!store.projectStoreIsConstructed)
        #expect(!FileManager.default.fileExists(atPath: fixture.projectsFile.path))
        #expect(store.windows.flatMap(\.sessions).count == sessionsBefore)
    }

    @Test func aVerbTheAppNeverHeardOfStillGetsTheSameWording() async throws {
        let fixture = try Fixture()
        let store = fixture.store(projects: false)
        let service = AppXPCService(store: { store }, clock: TestClock())
        let response = try await perform(service, verb: "projectDelete")
        #expect(response.error == "unknown verb: projectDelete")
    }

    // MARK: - projectList

    @Test func listReturnsSeededProjectsInStoreOrderWithOpenMarkers() async throws {
        let fixture = try Fixture()
        let store = fixture.store()
        let zed = fixture.project("Zed", panes: 3)
        let alpha = fixture.project("Alpha")
        try store.projectStore?.upsert(zed)
        try store.projectStore?.upsert(alpha)
        _ = try store.openProject(id: alpha.id)
        let service = AppXPCService(store: { store }, clock: TestClock())

        let response = try await perform(service, verb: XPCVerb.projectList)

        #expect(response.ok)
        let list = try JSONDecoder().decode(ProjectListReply.self, from: try #require(response.payload))
        #expect(list.projects.map(\.name) == ["Zed", "Alpha"])
        #expect(list.projects.map(\.paneCount) == [3, 1])
        #expect(list.projects.map(\.isOpen) == [false, true])
        #expect(list.projects.map(\.rootPath) == [fixture.root.path, fixture.root.path])
        #expect(list.projects.map(\.id) == [zed.id, alpha.id])
    }

    @Test func listIsRankedByRecencyWithOpenProjectsLast() async throws {
        let fixture = try Fixture()
        let store = fixture.store()
        var old = fixture.project("Old"), recent = fixture.project("Recent")
        old.lastOpenedAt = Date(timeIntervalSince1970: 100)
        recent.lastOpenedAt = Date(timeIntervalSince1970: 200)
        let never = fixture.project("Never"), busy = fixture.project("Busy")
        for project in [never, old, busy, recent] { try store.projectStore?.upsert(project) }
        store.projectUsageClock = { Date(timeIntervalSince1970: 300) }
        _ = try store.openProject(id: busy.id)
        let service = AppXPCService(store: { store }, clock: TestClock())

        let response = try await perform(service, verb: XPCVerb.projectList)

        let list = try JSONDecoder().decode(ProjectListReply.self, from: try #require(response.payload))
        #expect(list.projects.map(\.name) == ["Recent", "Old", "Never", "Busy"])
        #expect(list.projects.map(\.isOpen) == [false, false, false, true])
    }

    @Test func listOfAnEmptyStoreIsAnEmptyArray() async throws {
        let fixture = try Fixture()
        let store = fixture.store()
        let response = try await perform(AppXPCService(store: { store }, clock: TestClock()), verb: XPCVerb.projectList)
        #expect(response.ok)
        #expect(try JSONDecoder().decode(ProjectListReply.self, from: try #require(response.payload)).projects.isEmpty)
    }

    // MARK: - projectOpen

    @Test func openCreatesThenFocusesAndOpenNewCreatesAnother() async throws {
        let fixture = try Fixture()
        let store = fixture.store()
        let project = fixture.project("Batty")
        try store.projectStore?.upsert(project)
        let service = AppXPCService(store: { store }, clock: TestClock())
        let recorder = EventRecorder()
        defer { recorder.stop() }

        let first = try reply(try await open(service, "batty"))
        #expect(first.status == .opened)
        #expect(first.created)
        #expect(first.name == "Batty")
        let session = try #require(store.windows.flatMap(\.sessions).first { $0.id == first.sessionID })
        #expect(session.projectID == project.id)
        #expect(first.paneID == session.tree.focusedPaneID)

        let again = try reply(try await open(service, "BATTY"))
        #expect(!again.created)
        #expect(again.sessionID == first.sessionID)

        let copy = try reply(try await open(service, "Batty", openNew: true))
        #expect(copy.created)
        #expect(copy.sessionID != first.sessionID)
        #expect(store.windows.flatMap(\.sessions).filter { $0.projectID == project.id }.count == 2)

        let mine = recorder.payloads.filter { [first.sessionID, copy.sessionID].contains($0.sessionID) }
        #expect(mine.contains { $0.type == "session_created" && $0.sessionID == first.sessionID && $0.fromCli })
        #expect(mine.contains { $0.type == "session_focused" && $0.sessionID == first.sessionID && $0.fromCli })
        #expect(mine.contains { $0.type == "session_created" && $0.sessionID == copy.sessionID && $0.fromCli })
    }

    @Test func openingAnUnknownNameFailsAndListsTheCloseMatches() async throws {
        let fixture = try Fixture()
        let store = fixture.store()
        try store.projectStore?.upsert(fixture.project("Batty"))
        try store.projectStore?.upsert(fixture.project("Homelab"))
        let service = AppXPCService(store: { store }, clock: TestClock())
        let sessionsBefore = store.windows.flatMap(\.sessions).count

        let response = try await open(service, "Battey")

        #expect(response.ok == false)
        let message = try #require(response.error)
        #expect(message.contains("no Project named \"Battey\""))
        #expect(message.contains("\"Batty\""))
        #expect(!message.contains("Homelab"))
        #expect(store.windows.flatMap(\.sessions).count == sessionsBefore)
    }

    @Test func anUnknownNameWithNoCloseMatchPointsAtList() async throws {
        let fixture = try Fixture()
        let store = fixture.store()
        try store.projectStore?.upsert(fixture.project("Batty"))
        let response = try await open(AppXPCService(store: { store }, clock: TestClock()), "Completely Different")
        #expect(try #require(response.error).contains("batty project list"))
    }

    @Test func openingWithNoSavedProjectsSaysSo() async throws {
        let fixture = try Fixture()
        let store = fixture.store()
        let response = try await open(AppXPCService(store: { store }, clock: TestClock()), "Batty")
        #expect(try #require(response.error).contains("no saved Projects"))
    }

    @Test func aMalformedOpenRequestFails() async throws {
        let fixture = try Fixture()
        let store = fixture.store()
        let response = try await perform(AppXPCService(store: { store }, clock: TestClock()), verb: XPCVerb.projectOpen, payload: Data("nope".utf8))
        #expect(response.ok == false)
        #expect(response.error == "malformed project open request")
    }

    @Test func aMissingRootFailsWithoutCreatingASession() async throws {
        let fixture = try Fixture()
        let store = fixture.store()
        var project = fixture.project("Gone")
        project.rootPath = fixture.base.appendingPathComponent("missing").path
        try store.projectStore?.upsert(project)
        let sessionsBefore = store.windows.flatMap(\.sessions).count

        let response = try await open(AppXPCService(store: { store }, clock: TestClock()), "Gone")

        #expect(response.ok == false)
        #expect(try #require(response.error).contains("no longer exists"))
        #expect(store.windows.flatMap(\.sessions).count == sessionsBefore)
    }

    // MARK: - Startup-command trust sheet

    private func pendingRequest(in store: AppStateStore) throws -> ProjectStartupTrustRequest {
        try #require(store.windows.lazy.compactMap { $0.pendingStartupTrusts.first }.first)
    }

    @Test func theReplyWaitsForTheUsersAnswerToTheTrustSheet() async throws {
        let fixture = try Fixture()
        let store = fixture.store()
        try store.projectStore?.upsert(fixture.project("Batty", command: "./build.sh"))
        let clock = TestClock()
        let service = AppXPCService(store: { store }, clock: clock)
        let sessionsBefore = store.windows.flatMap(\.sessions).count

        let pending = Task { @MainActor in try await open(service, "Batty") }
        #expect(await clock.waitForSleepers(1))
        #expect(store.windows.flatMap(\.sessions).count == sessionsBefore, "no Session until the sheet is answered")
        let request = try pendingRequest(in: store)
        #expect(request.rows.map(\.command) == ["./build.sh"])

        store.resolveStartupTrust(requestID: request.id, choice: .openWithoutRunning)
        let opened = try reply(try await pending.value)

        #expect(opened.status == .opened)
        #expect(opened.created)
        #expect(store.windows.flatMap(\.sessions).contains { $0.id == opened.sessionID })
        #expect(clock.pendingCount == 0, "the bound timer is cancelled once the user answers")
    }

    @Test func dismissingTheTrustSheetFailsTheRequestAndOpensNothing() async throws {
        let fixture = try Fixture()
        let store = fixture.store()
        try store.projectStore?.upsert(fixture.project("Batty", command: "./build.sh"))
        let clock = TestClock()
        let service = AppXPCService(store: { store }, clock: clock)
        let sessionsBefore = store.windows.flatMap(\.sessions).count

        let pending = Task { @MainActor in try await open(service, "Batty") }
        #expect(await clock.waitForSleepers(1))
        store.cancelStartupTrust(requestID: try pendingRequest(in: store).id)
        let response = try await pending.value

        #expect(response.ok == false)
        #expect(try #require(response.error).contains("dismissed"))
        #expect(store.windows.flatMap(\.sessions).count == sessionsBefore)
        #expect(clock.pendingCount == 0)
    }

    @Test func anUnansweredSheetIsWithdrawnAtTheBoundAndTheReplySaysSo() async throws {
        let fixture = try Fixture()
        let store = fixture.store()
        try store.projectStore?.upsert(fixture.project("Batty", command: "./build.sh"))
        let clock = TestClock()
        let service = AppXPCService(store: { store }, clock: clock)
        let sessionsBefore = store.windows.flatMap(\.sessions).count

        let pending = Task { @MainActor in try await open(service, "batty") }
        #expect(await clock.waitForSleepers(1))
        let request = try pendingRequest(in: store)

        #expect(await clock.advance(by: .seconds(ProjectOpenRequest.confirmationBoundSeconds - 1)) == 0)
        #expect(store.windows.contains { !$0.pendingStartupTrusts.isEmpty }, "still waiting just inside the bound")
        #expect(await clock.advance(by: .seconds(1)) == 1)
        let response = try await pending.value

        #expect(response.ok)
        let timedOut = try reply(response)
        #expect(timedOut.status == .awaitingConfirmation)
        #expect(timedOut.sessionID == nil)
        #expect(timedOut.paneID == nil)
        #expect(!timedOut.created)
        #expect(timedOut.name == "Batty", "the stored name, not the request text")
        #expect(store.windows.allSatisfy { $0.pendingStartupTrusts.isEmpty }, "the sheet is withdrawn")
        #expect(store.windows.flatMap(\.sessions).count == sessionsBefore)

        store.resolveStartupTrust(requestID: request.id, choice: .run(rememberApproval: true))
        #expect(store.windows.flatMap(\.sessions).count == sessionsBefore, "a late answer to a withdrawn sheet opens nothing")
    }

    @Test func aFocusNeverPromptsEvenWhenCommandsAreUnapproved() async throws {
        let fixture = try Fixture()
        let store = fixture.store()
        let project = fixture.project("Batty", command: "./build.sh")
        try store.projectStore?.upsert(project)
        let existing = try store.openProject(id: project.id).session
        let clock = TestClock()

        let response = try await open(AppXPCService(store: { store }, clock: clock), "Batty")

        let focused = try reply(response)
        #expect(!focused.created)
        #expect(focused.sessionID == existing.id)
        #expect(clock.pendingCount == 0)
    }

    // MARK: - Activation

    private func activations(_ store: AppStateStore) -> ActivationLog {
        let log = ActivationLog()
        store.windowActivationObserver = { _ in log.count += 1 }
        return log
    }

    @Test func aCLIOpenThatNeedsApprovalBringsTheWindowForwardForTheSheet() async throws {
        let fixture = try Fixture()
        let store = fixture.store()
        try store.projectStore?.upsert(fixture.project("Batty", command: "./build.sh"))
        let log = activations(store)
        let clock = TestClock()
        let pending = Task { @MainActor in try await open(AppXPCService(store: { store }, clock: clock), "Batty") }
        #expect(await clock.waitForSleepers(1))
        #expect(log.count == 1, "the sheet's window is activated when it is queued")
        store.cancelStartupTrust(requestID: try pendingRequest(in: store).id)
        _ = try await pending.value
    }

    @Test func aGUIOpenThatNeedsApprovalDoesNotActivate() throws {
        let fixture = try Fixture()
        let store = fixture.store()
        let project = fixture.project("Batty", command: "./build.sh")
        try store.projectStore?.upsert(project)
        let log = activations(store)
        store.requestOpenProject(id: project.id, completion: { _ in })
        #expect(log.count == 0)
    }

    @Test func aCLICreateActivatesAndAGUICreateDoesNot() throws {
        let fixture = try Fixture()
        let store = fixture.store()
        let project = fixture.project("Batty")
        try store.projectStore?.upsert(project)
        let log = activations(store)
        _ = try store.openProject(id: project.id, mode: .openNew)
        #expect(log.count == 0)
        _ = try store.openProject(id: project.id, mode: .openNew, fromCli: true)
        #expect(log.count == 1)
    }

    @Test func aCLIFocusActivates() async throws {
        let fixture = try Fixture()
        let store = fixture.store()
        let project = fixture.project("Batty")
        try store.projectStore?.upsert(project)
        _ = try store.openProject(id: project.id)
        let log = activations(store)
        _ = try await open(AppXPCService(store: { store }, clock: TestClock()), "Batty")
        #expect(log.count == 1)
    }

    // MARK: - GUI opens while an auxiliary window is key

    private func titledWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                              styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    private func targets(_ store: AppStateStore) -> TargetLog {
        let log = TargetLog()
        store.windowActivationObserver = { log.ids.append($0.id) }
        return log
    }

    @Test func aGUICreateFromAnAuxiliaryKeyWindowBringsTheTargetForward() throws {
        let fixture = try Fixture()
        let store = fixture.store()
        let project = fixture.project("Batty", panes: 2)
        try store.projectStore?.upsert(project)
        let settings = titledWindow()
        store.keyWindowProvider = { settings }
        let log = targets(store)
        let target = try #require(store.defaultTargetWindow())

        let result = try store.openProject(id: project.id, mode: .openNew)

        #expect(result.wasCreated)
        #expect(target.sessions.contains { $0.id == result.session.id })
        #expect(target.selectedSession?.id == result.session.id)
        #expect(log.ids == [target.id])
    }

    @Test func aGUICreateFromAContentKeyWindowDoesNotActivate() throws {
        let fixture = try Fixture()
        let store = fixture.store()
        let project = fixture.project("Batty", panes: 2)
        try store.projectStore?.upsert(project)
        let content = titledWindow()
        store.registerNSWindow(content, for: store.windows[0].id)
        store.keyWindowProvider = { content }
        let log = targets(store)

        _ = try store.openProject(id: project.id, mode: .openNew)

        #expect(log.ids.isEmpty)
    }

    @Test func aTrustSheetRequestedFromAnAuxiliaryKeyWindowActivatesTheWindowItQueuedOn() throws {
        let fixture = try Fixture()
        let store = fixture.store()
        let project = fixture.project("Batty", command: "./build.sh", panes: 2)
        try store.projectStore?.upsert(project)
        let settings = titledWindow()
        store.keyWindowProvider = { settings }
        let log = targets(store)

        let requestID = try #require(store.requestOpenProject(id: project.id, mode: .openNew, completion: { _ in }))

        let queuedOn = try #require(store.windows.first { $0.pendingStartupTrusts.contains { $0.id == requestID } })
        #expect(log.ids == [queuedOn.id])
        store.cancelStartupTrust(requestID: requestID)
    }

    @Test func aTrustSheetRequestedFromAContentKeyWindowDoesNotActivate() throws {
        let fixture = try Fixture()
        let store = fixture.store()
        let project = fixture.project("Batty", command: "./build.sh", panes: 2)
        try store.projectStore?.upsert(project)
        let content = titledWindow()
        store.registerNSWindow(content, for: store.windows[0].id)
        store.keyWindowProvider = { content }
        let log = targets(store)

        let requestID = try #require(store.requestOpenProject(id: project.id, mode: .openNew, completion: { _ in }))

        #expect(log.ids.isEmpty)
        store.cancelStartupTrust(requestID: requestID)
    }

    @Test func aCLICreateStillActivatesExactlyOnceFromAnAuxiliaryKeyWindow() throws {
        let fixture = try Fixture()
        let store = fixture.store()
        let project = fixture.project("Batty", panes: 2)
        try store.projectStore?.upsert(project)
        let settings = titledWindow()
        store.keyWindowProvider = { settings }
        let log = targets(store)

        _ = try store.openProject(id: project.id, mode: .openNew, fromCli: true)

        #expect(log.ids.count == 1)
    }

    @Test func focusingAnOpenProjectFromAnAuxiliaryKeyWindowActivatesOnce() throws {
        let fixture = try Fixture()
        let store = fixture.store()
        let project = fixture.project("Batty", panes: 2)
        try store.projectStore?.upsert(project)
        _ = try store.openProject(id: project.id)
        let settings = titledWindow()
        store.keyWindowProvider = { settings }
        let log = targets(store)

        let result = try store.openProject(id: project.id)

        #expect(!result.wasCreated)
        #expect(log.ids.count == 1)
    }

    @Test func flagOffGUIOpenFromAnAuxiliaryKeyWindowActivatesNothing() throws {
        let fixture = try Fixture()
        let store = fixture.store(projects: false)
        let settings = titledWindow()
        store.keyWindowProvider = { settings }
        let log = targets(store)

        var failure: Error?
        store.requestOpenProject(id: UUID(), completion: { if case .failure(let e) = $0 { failure = e } })

        #expect(failure as? ProjectOpenError == .featureDisabled)
        #expect(log.ids.isEmpty)
    }

    @Test func flagOffOpenProjectFromAnAuxiliaryKeyWindowThrowsAndActivatesNothing() throws {
        let fixture = try Fixture()
        let store = fixture.store(projects: false)
        let settings = titledWindow()
        store.keyWindowProvider = { settings }
        let log = targets(store)

        #expect(throws: ProjectOpenError.featureDisabled) {
            try store.openProject(id: UUID(), mode: .openNew)
        }
        #expect(log.ids.isEmpty)
    }

    @Test func aPickerToggleNamingAWindowIsHandledByThatWindowOnly() {
        let named = WindowID(), other = WindowID()
        let info: [AnyHashable: Any] = [ProjectPickerToggle.windowIDKey: named]
        #expect(ProjectPickerToggle.shouldHandle(userInfo: info, windowID: named, isKeyWindow: false))
        #expect(!ProjectPickerToggle.shouldHandle(userInfo: info, windowID: other, isKeyWindow: true))
    }

    @Test func aPickerToggleNamingNoWindowIsHandledByTheKeyWindowOnly() {
        let id = WindowID()
        #expect(ProjectPickerToggle.shouldHandle(userInfo: nil, windowID: id, isKeyWindow: true))
        #expect(!ProjectPickerToggle.shouldHandle(userInfo: nil, windowID: id, isKeyWindow: false))
        #expect(!ProjectPickerToggle.shouldHandle(userInfo: ["other": 1], windowID: id, isKeyWindow: false))
    }

    // MARK: - Wire shapes

    @Test func openRequestHasNoFieldThatSkipsThePrompt() throws {
        let data = try JSONEncoder().encode(ProjectOpenRequest(name: "Batty", openNew: true))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["name", "openNew"])
    }

    @Test func payloadsRoundTripOffTheMainActor() async throws {
        let entry = ProjectListEntry(id: UUID(), name: "A", rootPath: "/a", paneCount: 2, isOpen: true)
        let list = ProjectListReply(projects: [entry])
        let opened = ProjectOpenReply(status: .opened, name: "A", sessionID: UUID(), paneID: UUID(), created: true)
        let waiting = ProjectOpenReply(status: .awaitingConfirmation, name: "A", sessionID: nil, paneID: nil, created: false)
        let roundTripped = await Task.detached {
            let encoder = JSONEncoder(), decoder = JSONDecoder()
            return (
                try? decoder.decode(ProjectListReply.self, from: encoder.encode(list)),
                try? decoder.decode(ProjectOpenReply.self, from: encoder.encode(opened)),
                try? decoder.decode(ProjectOpenReply.self, from: encoder.encode(waiting)))
        }.value
        #expect(roundTripped.0 == list)
        #expect(roundTripped.1 == opened)
        #expect(roundTripped.2 == waiting)
    }
}

struct ProjectNameMatchingTests {
    private let names = ["Batty", "Homelab", "Batty Docs", "x"]

    @Test func substringsInEitherDirectionAndSmallTyposMatch() {
        #expect(ProjectNameMatching.closeMatches(to: "batt", in: names) == ["Batty", "Batty Docs"])
        #expect(ProjectNameMatching.closeMatches(to: "Battey", in: names) == ["Batty"])
        #expect(ProjectNameMatching.closeMatches(to: "Homelabs", in: names) == ["Homelab"])
    }

    @Test func stringsUnderThreeCharactersNeverMatch() {
        #expect(ProjectNameMatching.closeMatches(to: "b", in: names).isEmpty)
        #expect(ProjectNameMatching.closeMatches(to: "ba", in: names).isEmpty)
        #expect(ProjectNameMatching.closeMatches(to: "xyz", in: names).isEmpty, "the one-letter name \"x\" is not a match for anything")
        #expect(ProjectNameMatching.closeMatches(to: "bat", in: names) == ["Batty", "Batty Docs"])
    }

    @Test func unrelatedOrBlankQueriesMatchNothing() {
        #expect(ProjectNameMatching.closeMatches(to: "Completely Different", in: names).isEmpty)
        #expect(ProjectNameMatching.closeMatches(to: "   ", in: names).isEmpty)
    }
}
