// AppStateStoreServerTests.swift

import BattyXPCCore
import Foundation
import Testing
@testable import BattyKit

/// A store whose servers use fakes: no real scans, probes or signals.
@MainActor
final class ServerStoreFixture {
    let defaults = UserDefaults(suiteName: "AppStateStoreServerTests-\(UUID().uuidString)")!
    let clock = TestClock()
    let scanner = FakePortScanner()
    let probe = FakeHTTPProbe()
    let signaller = FakeProcessSignaller()
    let store: AppStateStore
    var copied: [String] = []
    var opened: [URL] = []

    init(servers: Bool = true) {
        store = AppStateStore(preferences: defaults, featureFlags: FeatureFlags(sharedProjectImages: false, servers: servers))
        let clock = clock, scanner = scanner, probe = probe, signaller = signaller
        store.makeServerEntry = { port, url, backend in
            ServerEntry(
                port: port, url: url, backend: backend, clock: clock, scanner: scanner,
                probe: probe, commandLineProvider: { _ in nil },
                signaller: signaller, processTable: FakeProcessTable(tabID: UUID()), opener: { _ in }, startsBackendOnSetUp: false
            )
        }
        store.copyToPasteboard = { [weak self] in self?.copied.append($0) }
        store.openURLInBrowser = { [weak self] in self?.opened.append($0) }
    }

    var session: SessionRuntime { store.sessions[0] }
    var callingPaneID: UUID { session.tree.focusedPaneID }

    func start(port: Int = 8083, command: String = "go run .", split: ServerSplit? = nil, paneID: UUID? = nil, url: String? = nil) throws -> ServerXPCResult {
        try store.startServerForXPC(ServerStartRequest(paneID: paneID ?? callingPaneID, port: port, command: command, workingDirectory: "/tmp", url: url, split: split)).get()
    }

    func attach(port: Int = 8083, command: String? = nil) throws -> ServerXPCResult {
        try store.attachServerForXPC(ServerAttachRequest(paneID: callingPaneID, port: port, command: command, workingDirectory: command == nil ? nil : "/tmp")).get()
    }

    func pane(_ id: UUID?) -> PaneRuntime? {
        session.tree.allPanes.first { $0.id == id }
    }
}

/// The direction of the split whose children are exactly `a` and `b`.
@MainActor
private func splitDirection(between a: UUID, and b: UUID, in node: SplitTreeNode) -> SplitDirection? {
    guard case .split(_, let direction, _, let left, let right) = node else { return nil }
    let leftIDs = Set(left.allLeafPanes.map(\.id)), rightIDs = Set(right.allLeafPanes.map(\.id))
    if (leftIDs.contains(a) && rightIDs.contains(b)) || (leftIDs.contains(b) && rightIDs.contains(a)) { return direction }
    return splitDirection(between: a, and: b, in: left) ?? splitDirection(between: a, and: b, in: right)
}

@MainActor
struct AppStateStoreServerTests {
    @Test func startRegistersAnEntryAndSplitsATerminalPaneRightOfTheCaller() throws {
        let fixture = ServerStoreFixture()
        let caller = fixture.callingPaneID
        let result = try fixture.start()
        let reply = fixture.store.serverReply(result)
        #expect(result.created)
        #expect(fixture.store.servers.entries.map(\.id) == [result.entry.id])
        #expect(reply.serverID == result.entry.id)
        let terminalID = try #require(reply.terminalPaneID)
        #expect(fixture.pane(terminalID)?.tabs.map(\.id) == reply.tabID.map { [$0] })
        #expect(splitDirection(between: caller, and: terminalID, in: fixture.session.tree.root) == .horizontal)
        #expect(fixture.session.tree.allPanes.count == 2)
        #expect(fixture.session.tree.allPanes.allSatisfy { $0.kind == .terminal })
    }

    @Test func startHonorsSplitDownOverride() throws {
        let fixture = ServerStoreFixture()
        let caller = fixture.callingPaneID
        let result = try fixture.start(split: .down)
        let terminalID = try #require(fixture.store.serverReply(result).terminalPaneID)
        #expect(splitDirection(between: caller, and: terminalID, in: fixture.session.tree.root) == .vertical)
    }

    @Test func startKeepsFocusOnTheCallingPane() throws {
        let fixture = ServerStoreFixture()
        let caller = fixture.callingPaneID
        _ = try fixture.start()
        #expect(fixture.session.tree.focusedPaneID == caller)
    }

    @Test func startTwiceOnSamePortReusesEntryAndTabAndRestarts() async throws {
        let fixture = ServerStoreFixture()
        let first = try fixture.start()
        let firstReply = fixture.store.serverReply(first)
        let paneCount = fixture.session.tree.allPanes.count
        let second = try fixture.start()
        #expect(fixture.store.servers.entries.count == 1)
        await second.entry.awaitPendingWork()
        #expect(!second.created)
        #expect(second.entry === first.entry)
        #expect(fixture.store.serverReply(second).tabID == firstReply.tabID)
        #expect(fixture.session.tree.allPanes.count == paneCount)
    }

    @Test func startOnSamePortWithNewCommandReplacesTheCommand() throws {
        let fixture = ServerStoreFixture()
        let first = try fixture.start(command: "go run .")
        _ = try fixture.start(command: "go run ./cmd/site")
        #expect(first.entry.backend.command == "go run ./cmd/site")
    }

    @Test func startAfterTerminalClosedRegistersAFreshEntry() async throws {
        let fixture = ServerStoreFixture()
        let first = try fixture.start()
        let oldTerminal = try #require(fixture.store.serverReply(first).terminalPaneID)
        fixture.session.tree.removePane(id: oldTerminal)
        await first.entry.performTick()
        #expect(fixture.store.servers.entries.isEmpty)
        let second = try fixture.start()
        #expect(second.created)
        #expect(second.entry.id != first.entry.id)
        let newTerminal = try #require(fixture.store.serverReply(second).terminalPaneID)
        #expect(newTerminal != oldTerminal)
    }

    @Test func differentPortsGetDifferentEntries() throws {
        let fixture = ServerStoreFixture()
        let a = try fixture.start(port: 8083)
        let b = try fixture.start(port: 8084)
        #expect(a.entry.id != b.entry.id)
        #expect(b.created)
        #expect(fixture.store.servers.entries.count == 2)
    }

    @Test func samePortFromAnotherSessionReusesTheEntry() throws {
        let fixture = ServerStoreFixture()
        let a = try fixture.start()
        let other = try #require(fixture.store.addSession(title: "Other"))
        let b = try fixture.start(paneID: other.tree.focusedPaneID)
        #expect(a.entry === b.entry)
        #expect(!b.created)
    }

    @Test func attachTwiceReturnsTheSameEntryUnchanged() throws {
        let fixture = ServerStoreFixture()
        let first = try fixture.attach()
        let second = try fixture.attach(command: "npm start")
        #expect(second.entry === first.entry)
        #expect(!second.created)
        #expect(second.entry.backend.command == nil)
    }

    @Test func attachOpensNoPane() throws {
        let fixture = ServerStoreFixture()
        let count = fixture.session.tree.allPanes.count
        let result = try fixture.attach()
        #expect(fixture.session.tree.allPanes.count == count)
        #expect(result.entry.backend.kind == .external)
        #expect(fixture.store.servers.entry(port: 8083) === result.entry)
    }

    @Test func startOnAnAttachedPortConvertsItToATerminalBackend() async throws {
        let fixture = ServerStoreFixture()
        let attached = try fixture.attach()
        let started = try fixture.start()
        await started.entry.awaitPendingWork()
        #expect(started.entry === attached.entry)
        #expect(started.entry.backend.kind == .terminal)
        #expect(fixture.store.serverReply(started).terminalPaneID != nil)
    }

    @Test func stopAndRestartResolveByPortAppWide() async throws {
        let fixture = ServerStoreFixture()
        let started = try fixture.start()
        let other = try #require(fixture.store.addSession(title: "Other"))
        let restarted = try fixture.store.restartServerForXPC(ServerControlRequest(paneID: other.tree.focusedPaneID, port: 8083)).get()
        #expect(restarted.entry === started.entry)
        await restarted.entry.awaitPendingWork()
        let second = try fixture.start(port: 8084)
        let stopped = try fixture.store.stopServerForXPC(ServerControlRequest(paneID: other.tree.focusedPaneID, port: 8084)).get()
        #expect(stopped.entry === second.entry)
        await stopped.entry.awaitPendingWork()
        #expect(stopped.entry.state == .stopped(exitCode: nil, reason: .requested))
        #expect(fixture.store.servers.entry(port: 8084) == nil)
    }

    @Test func stopResolvesByServerID() async throws {
        let fixture = ServerStoreFixture()
        let started = try fixture.start()
        let stopped = try fixture.store.stopServerForXPC(ServerControlRequest(serverID: started.entry.id)).get()
        #expect(stopped.entry === started.entry)
        await stopped.entry.awaitPendingWork()
        #expect(fixture.store.servers.entry(id: started.entry.id) == nil)
    }

    @Test func unknownPortIsAFailure() {
        let fixture = ServerStoreFixture()
        #expect(throws: ServerXPCError.unknownServer) {
            try fixture.store.stopServerForXPC(ServerControlRequest(paneID: fixture.callingPaneID, port: 9999)).get()
        }
        #expect(throws: ServerXPCError.unknownServer) {
            try fixture.store.stopServerForXPC(ServerControlRequest(serverID: UUID())).get()
        }
    }

    @Test func everyVerbFailsWithFlagOff() {
        let fixture = ServerStoreFixture(servers: false)
        #expect(throws: ServerXPCError.flagOff) { try fixture.start() }
        #expect(throws: ServerXPCError.flagOff) { try fixture.attach() }
        #expect(throws: ServerXPCError.flagOff) { try fixture.store.stopServerForXPC(ServerControlRequest(port: 8083)).get() }
        #expect(throws: ServerXPCError.flagOff) { try fixture.store.restartServerForXPC(ServerControlRequest(port: 8083)).get() }
        #expect(fixture.session.tree.allPanes.count == 1)
        #expect(fixture.store.servers.entries.isEmpty)
    }
}

@MainActor
struct ServerEntryActionsTests {
    @Test func copyURLWritesTheLoopbackURL() throws {
        let fixture = ServerStoreFixture()
        let entry = try fixture.start(port: 8123).entry
        fixture.store.copyServerURL(entry)
        #expect(fixture.copied == ["http://127.0.0.1:8123/"])
    }

    @Test func copyURLUsesAnExplicitURL() throws {
        let fixture = ServerStoreFixture()
        let entry = try fixture.start(url: "http://localhost:8083/app").entry
        fixture.store.copyServerURL(entry)
        #expect(fixture.copied == ["http://localhost:8083/app"])
    }

    @Test func copyTailnetURLDoesNothingWithoutOne() throws {
        let fixture = ServerStoreFixture()
        let entry = try fixture.start().entry
        fixture.store.copyServerTailnetURL(entry)
        #expect(fixture.copied.isEmpty)
    }

    @Test func openInBrowserOpensTheEntryURL() throws {
        let fixture = ServerStoreFixture()
        let entry = try fixture.start(port: 8124).entry
        fixture.store.openServerInBrowser(entry)
        #expect(fixture.opened.map(\.absoluteString) == ["http://127.0.0.1:8124/"])
    }

    @Test func showTerminalJumpsToTheServersTab() throws {
        let fixture = ServerStoreFixture()
        let caller = fixture.callingPaneID
        let result = try fixture.start()
        let reply = fixture.store.serverReply(result)
        let terminalID = try #require(reply.terminalPaneID)
        #expect(fixture.session.tree.focusedPaneID == caller)
        fixture.store.showServerTerminal(result.entry)
        #expect(fixture.session.tree.focusedPaneID == terminalID)
        #expect(fixture.pane(terminalID)?.activeTabID == reply.tabID)
    }

    @Test func showTerminalIsANoOpForAnAttachedServer() throws {
        let fixture = ServerStoreFixture()
        let caller = fixture.callingPaneID
        let entry = try fixture.attach().entry
        #expect(fixture.store.serverTerminalTabID(entry) == nil)
        fixture.store.showServerTerminal(entry)
        #expect(fixture.session.tree.focusedPaneID == caller)
    }

    @Test func rowOffersStopAndRestartOnlyForManagedKinds() {
        #expect(ServerEntryDisplay.offersStopAndRestart(kind: .terminal))
        #expect(ServerEntryDisplay.offersStopAndRestart(kind: .inApp))
        #expect(!ServerEntryDisplay.offersStopAndRestart(kind: .external))
    }
}

@MainActor
struct AppXPCServiceServerTests {
    private func respond(_ fixture: ServerStoreFixture, verb: String, payload: Data?) async -> XPCResponse {
        await AppXPCService.serverResponse(verb: verb, payload: payload, store: fixture.store, clock: fixture.clock)
    }

    private func startPayload(_ fixture: ServerStoreFixture, wait: Bool = false) throws -> Data {
        try JSONEncoder().encode(ServerStartRequest(paneID: fixture.callingPaneID, port: 8083, command: "go run .", workingDirectory: "/tmp", wait: wait, waitTimeoutSeconds: 30))
    }

    @Test func serverStartReplyCarriesServerIDTerminalPaneAndTabIDs() async throws {
        let fixture = ServerStoreFixture()
        let response = await respond(fixture, verb: XPCVerb.serverStart, payload: try startPayload(fixture))
        #expect(response.ok)
        let reply = try JSONDecoder().decode(ServerReply.self, from: try #require(response.payload))
        #expect(reply.created)
        #expect(reply.serverID == fixture.store.servers.entries.first?.id)
        #expect(reply.terminalPaneID != nil)
        #expect(reply.tabID != nil)
        #expect(reply.url == "http://127.0.0.1:8083/")
        #expect(reply.state == .starting)
    }

    @Test func waitRepliesWhenListening() async throws {
        let fixture = ServerStoreFixture()
        let payload = try startPayload(fixture, wait: true)
        let task = Task { await respond(fixture, verb: XPCVerb.serverStart, payload: payload) }
        await fixture.clock.waitForSleepers(2)
        let content = try #require(fixture.store.servers.entries.first)
        fixture.scanner.listener = 4321
        await content.performTick()
        let response = await task.value
        #expect(response.ok)
        let reply = try JSONDecoder().decode(ServerReply.self, from: try #require(response.payload))
        #expect(reply.state == .listening)
        #expect(reply.pid == 4321)
    }

    @Test func waitRepliesCrashedWithExitCode() async throws {
        let fixture = ServerStoreFixture()
        let payload = try startPayload(fixture, wait: true)
        let task = Task { await respond(fixture, verb: XPCVerb.serverStart, payload: payload) }
        await fixture.clock.waitForSleepers(2)
        let content = try #require(fixture.store.servers.entries.first)
        content.receive(.commandFinished(exitCode: 2))
        let response = await task.value
        #expect(!response.ok)
        #expect(response.error == "server exited (code 2)")
    }

    @Test func waitTimesOutOnTheInjectedClock() async throws {
        let fixture = ServerStoreFixture()
        let payload = try startPayload(fixture, wait: true)
        let task = Task { await respond(fixture, verb: XPCVerb.serverStart, payload: payload) }
        await fixture.clock.waitForSleepers(2)
        await fixture.clock.advance(by: .seconds(30))
        let response = await task.value
        #expect(!response.ok)
        #expect(response.error == "timed out; still starting")
    }

    @Test(arguments: [1e300, Double.greatestFiniteMagnitude, 0, -1, 86_401])
    func anOutOfRangeWaitTimeoutIsRefusedBeforeStartingOrAttaching(_ seconds: Double) async throws {
        let fixture = ServerStoreFixture()
        let panesBefore = fixture.session.tree.allPanes.count
        let start = try JSONEncoder().encode(ServerStartRequest(paneID: fixture.callingPaneID, port: 8083, command: "go run .", workingDirectory: "/tmp", wait: true, waitTimeoutSeconds: seconds))
        let startResponse = await respond(fixture, verb: XPCVerb.serverStart, payload: start)
        #expect(!startResponse.ok)
        #expect(startResponse.error?.hasPrefix("wait timeout must be") == true)

        let attach = try JSONEncoder().encode(ServerAttachRequest(paneID: fixture.callingPaneID, port: 8083, wait: true, waitTimeoutSeconds: seconds))
        let attachResponse = await respond(fixture, verb: XPCVerb.serverAttach, payload: attach)
        #expect(!attachResponse.ok)
        #expect(attachResponse.error?.hasPrefix("wait timeout must be") == true)

        #expect(fixture.session.tree.allPanes.count == panesBefore)
    }

    @Test(arguments: [Double.infinity, -Double.infinity, Double.nan, 1e300])
    func firstStateLeavingStartingReturnsAtOnceForAnInvalidTimeout(_ seconds: Double) async throws {
        let fixture = ServerStoreFixture()
        let content = try fixture.start().entry
        #expect(await AppXPCService.firstStateLeavingStarting(content, clock: fixture.clock, timeout: seconds) == nil)
    }

    @Test func malformedPayloadIsAFailure() async {
        let fixture = ServerStoreFixture()
        let response = await respond(fixture, verb: XPCVerb.serverStart, payload: Data("{}".utf8))
        #expect(!response.ok)
        #expect(response.error == "malformed server start request")
    }
}
