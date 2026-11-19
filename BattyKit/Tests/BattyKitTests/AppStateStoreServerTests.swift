// AppStateStoreServerTests.swift

import BattyXPCCore
import Foundation
import Testing
@testable import BattyKit

/// A store whose Server Panes use fakes: no real scans, probes or signals.
@MainActor
final class ServerStoreFixture {
    let defaults = UserDefaults(suiteName: "AppStateStoreServerTests-\(UUID().uuidString)")!
    let clock = TestClock()
    let scanner = FakePortScanner()
    let probe = FakeHTTPProbe()
    let signaller = FakeProcessSignaller()
    let store: AppStateStore

    init(serverPane: Bool = true) {
        store = AppStateStore(preferences: defaults, featureFlags: FeatureFlags(sharedProjectImages: false, serverPane: serverPane))
        let clock = clock, scanner = scanner, probe = probe, signaller = signaller
        store.makeServerContent = { port, url, statsURL, backend in
            ServerPaneContent(
                port: port, url: url, statsURL: statsURL, backend: backend, clock: clock, scanner: scanner,
                probe: probe, statsFetcher: FakeStatsFetcher(), metricsProvider: { _ in nil }, commandLineProvider: { _ in nil },
                signaller: signaller, processTable: FakeProcessTable(tabID: UUID()), opener: { _ in }, startsBackendOnSetUp: false
            )
        }
    }

    var session: SessionRuntime { store.sessions[0] }
    var callingPaneID: UUID { session.tree.focusedPaneID }

    func start(port: Int = 8083, command: String = "go run .", split: ServerSplit? = nil, paneID: UUID? = nil) throws -> ServerXPCResult {
        try store.startServerForXPC(ServerStartRequest(paneID: paneID ?? callingPaneID, port: port, command: command, workingDirectory: "/tmp", split: split)).get()
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
    @Test func startCreatesServerPaneThenTerminalPaneBelowIt() throws {
        let fixture = ServerStoreFixture()
        let caller = fixture.callingPaneID
        let result = try fixture.start()
        let reply = fixture.store.serverReply(result)
        #expect(result.created)
        #expect(fixture.pane(result.paneID)?.kind == .server)
        let terminalID = try #require(reply.terminalPaneID)
        #expect(fixture.pane(terminalID)?.kind == .terminal)
        #expect(fixture.pane(terminalID)?.tabs.map(\.id) == reply.tabID.map { [$0] })
        #expect(splitDirection(between: result.paneID, and: terminalID, in: fixture.session.tree.root) == .vertical)
        #expect(splitDirection(between: caller, and: result.paneID, in: fixture.session.tree.root) == .horizontal)
        #expect(fixture.session.tree.root.allLeafPanes.map(\.id).firstIndex(of: result.paneID)! < fixture.session.tree.root.allLeafPanes.map(\.id).firstIndex(of: terminalID)!)
    }

    @Test func startHonorsSplitDownOverride() throws {
        let fixture = ServerStoreFixture()
        let caller = fixture.callingPaneID
        let result = try fixture.start(split: .down)
        #expect(splitDirection(between: caller, and: result.paneID, in: fixture.session.tree.root) == .vertical)
    }

    @Test func startUsesThePlacementSettingWhenNoSplitGiven() throws {
        let fixture = ServerStoreFixture()
        fixture.defaults.set(ServerPanePlacement.below.rawValue, forKey: SettingsPreference.serverPanePlacementKey)
        let caller = fixture.callingPaneID
        let result = try fixture.start()
        #expect(splitDirection(between: caller, and: result.paneID, in: fixture.session.tree.root) == .vertical)
    }

    @Test func startKeepsFocusOnTheCallingPane() throws {
        let fixture = ServerStoreFixture()
        let caller = fixture.callingPaneID
        _ = try fixture.start()
        #expect(fixture.session.tree.focusedPaneID == caller)
    }

    @Test func startTwiceOnSamePortReusesPaneAndTabAndRestarts() async throws {
        let fixture = ServerStoreFixture()
        let first = try fixture.start()
        let firstReply = fixture.store.serverReply(first)
        let paneCount = fixture.session.tree.allPanes.count
        let second = try fixture.start()
        await second.content.awaitPendingWork()
        #expect(!second.created)
        #expect(second.paneID == first.paneID)
        #expect(fixture.store.serverReply(second).tabID == firstReply.tabID)
        #expect(fixture.session.tree.allPanes.count == paneCount)
    }

    @Test func startOnSamePortWithNewCommandReplacesTheCommand() throws {
        let fixture = ServerStoreFixture()
        let first = try fixture.start(command: "go run .")
        _ = try fixture.start(command: "go run ./cmd/site")
        #expect(first.content.backend.command == "go run ./cmd/site")
    }

    @Test func startShowsAHiddenServerPaneForThePort() throws {
        let fixture = ServerStoreFixture()
        let first = try fixture.start()
        fixture.store.hidePane(id: first.paneID)
        #expect(fixture.pane(first.paneID)?.isHidden == true)
        _ = try fixture.start()
        #expect(fixture.pane(first.paneID)?.isHidden == false)
    }

    @Test func startAfterTerminalClosedMakesANewTerminalPaneUnderTheServerPane() throws {
        let fixture = ServerStoreFixture()
        let first = try fixture.start()
        let oldTerminal = try #require(fixture.store.serverReply(first).terminalPaneID)
        fixture.session.tree.removePane(id: oldTerminal)
        _ = try fixture.start()
        let newTerminal = try #require(fixture.store.serverReply(first).terminalPaneID)
        #expect(newTerminal != oldTerminal)
        #expect(splitDirection(between: first.paneID, and: newTerminal, in: fixture.session.tree.root) == .vertical)
    }

    @Test func differentPortsGetDifferentPanes() throws {
        let fixture = ServerStoreFixture()
        let a = try fixture.start(port: 8083)
        let b = try fixture.start(port: 8084)
        #expect(a.paneID != b.paneID)
        #expect(b.created)
    }

    @Test func samePortInAnotherSessionIsADifferentPane() throws {
        let fixture = ServerStoreFixture()
        let a = try fixture.start()
        let other = try #require(fixture.store.addSession(title: "Other"))
        let b = try fixture.start(paneID: other.tree.focusedPaneID)
        #expect(a.paneID != b.paneID)
        #expect(b.created)
    }

    @Test func attachTwiceReturnsTheSamePaneUnchanged() throws {
        let fixture = ServerStoreFixture()
        let first = try fixture.attach()
        let count = fixture.session.tree.allPanes.count
        let second = try fixture.attach(command: "npm start")
        #expect(second.paneID == first.paneID)
        #expect(!second.created)
        #expect(second.content.backend.command == nil)
        #expect(fixture.session.tree.allPanes.count == count)
    }

    @Test func startOnAnAttachedPortConvertsItToATerminalBackend() async throws {
        let fixture = ServerStoreFixture()
        let attached = try fixture.attach()
        let started = try fixture.start()
        await started.content.awaitPendingWork()
        #expect(started.paneID == attached.paneID)
        #expect(started.content.backend.kind == .terminal)
        #expect(fixture.store.serverReply(started).terminalPaneID != nil)
    }

    @Test func stopAndRestartResolveByPortWithinTheSession() async throws {
        let fixture = ServerStoreFixture()
        let started = try fixture.start()
        let stopped = try fixture.store.stopServerForXPC(ServerControlRequest(paneID: fixture.callingPaneID, port: 8083)).get()
        #expect(stopped.paneID == started.paneID)
        await stopped.content.awaitPendingWork()
        #expect(stopped.content.state == .stopped(exitCode: nil, reason: .requested))
        let restarted = try fixture.store.restartServerForXPC(ServerControlRequest(serverPaneID: started.paneID)).get()
        #expect(restarted.paneID == started.paneID)
    }

    @Test func unknownPortIsAFailure() {
        let fixture = ServerStoreFixture()
        #expect(throws: ServerXPCError.unknownServer) {
            try fixture.store.stopServerForXPC(ServerControlRequest(paneID: fixture.callingPaneID, port: 9999)).get()
        }
    }

    @Test func everyVerbFailsWithFlagOff() {
        let fixture = ServerStoreFixture(serverPane: false)
        #expect(throws: ServerXPCError.flagOff) { try fixture.start() }
        #expect(throws: ServerXPCError.flagOff) { try fixture.attach() }
        #expect(throws: ServerXPCError.flagOff) { try fixture.store.stopServerForXPC(ServerControlRequest(port: 8083)).get() }
        #expect(throws: ServerXPCError.flagOff) { try fixture.store.restartServerForXPC(ServerControlRequest(port: 8083)).get() }
        #expect(fixture.session.tree.allPanes.count == 1)
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

    @Test func serverStartReplyCarriesPaneTerminalPaneAndTabIDs() async throws {
        let fixture = ServerStoreFixture()
        let response = await respond(fixture, verb: XPCVerb.serverStart, payload: try startPayload(fixture))
        #expect(response.ok)
        let reply = try JSONDecoder().decode(ServerReply.self, from: try #require(response.payload))
        #expect(reply.created)
        #expect(reply.terminalPaneID != nil)
        #expect(reply.tabID != nil)
        #expect(reply.url == "http://localhost:8083/")
        #expect(reply.state == .starting)
    }

    @Test func waitRepliesWhenListening() async throws {
        let fixture = ServerStoreFixture()
        let payload = try startPayload(fixture, wait: true)
        let task = Task { await respond(fixture, verb: XPCVerb.serverStart, payload: payload) }
        await fixture.clock.waitForSleepers(2)
        let content = try #require(fixture.session.tree.allPanes.compactMap { $0.content as? ServerPaneContent }.first)
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
        let content = try #require(fixture.session.tree.allPanes.compactMap { $0.content as? ServerPaneContent }.first)
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

    @Test func malformedPayloadIsAFailure() async {
        let fixture = ServerStoreFixture()
        let response = await respond(fixture, verb: XPCVerb.serverStart, payload: Data("{}".utf8))
        #expect(!response.ok)
        #expect(response.error == "malformed server start request")
    }
}
