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
    let tailscale = FakeTailscaleRunner()
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
        store.serverPortScanner = scanner
        store.tailnet.runner = tailscale
        store.tailnet.locate = { FakeTailscaleRunner.executable }
        store.copyToPasteboard = { [weak self] in self?.copied.append($0) }
        store.openURLInBrowser = { [weak self] in self?.opened.append($0) }
    }

    var session: SessionRuntime { store.sessions[0] }
    var callingPaneID: UUID { session.tree.focusedPaneID }

    func start(port: Int = 8083, command: String = "go run .", split: ServerSplit? = nil, paneID: UUID? = nil, url: String? = nil) throws -> ServerXPCResult {
        try store.startServerForXPC(ServerStartRequest(paneID: paneID ?? callingPaneID, port: port, command: command, workingDirectory: "/tmp", url: url, split: split)).get()
    }

    func start(port: Int = 8083, processView: Bool?) throws -> ServerXPCResult {
        try store.startServerForXPC(ServerStartRequest(paneID: callingPaneID, port: port, command: "go run .", workingDirectory: "/tmp", processView: processView)).get()
    }

    /// Shares `port`; the fake scanner must report a listener first.
    func share(port: Int = 8083, name: String? = nil, processView: Bool? = nil, split: ServerSplit? = nil) async throws -> ServerXPCResult {
        try await store.shareServerForXPC(ServerShareRequest(paneID: callingPaneID, port: port, name: name, split: split, processView: processView)).get()
    }

    var processStatusPanes: [PaneRuntime] {
        session.tree.allPanes.filter { $0.kind == .processStatus }
    }

    func processTarget(_ id: UUID?) -> ProcessStatusPaneContent.Target? {
        (pane(id)?.content as? ProcessStatusPaneContent)?.target
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

    @Test func shareOfANonListeningPortFails() async {
        let fixture = ServerStoreFixture()
        let count = fixture.session.tree.allPanes.count
        await #expect(throws: ServerXPCError.nothingListening(8083)) { try await fixture.share() }
        #expect(fixture.store.servers.entries.isEmpty)
        #expect(fixture.session.tree.allPanes.count == count)
    }

    @Test func shareRegistersAnExternalEntryAndOpensOneProcessStatusPaneOnTheListener() async throws {
        let fixture = ServerStoreFixture()
        let caller = fixture.callingPaneID
        fixture.scanner.listener = FakeProcessTable.listener
        let result = try await fixture.share(name: "web")
        #expect(result.created)
        #expect(result.entry.backend.kind == .external)
        #expect(ServerEntryDisplay.name(for: result.entry) == "web")
        let reply = fixture.store.serverReply(result)
        #expect(reply.kind == .external)
        #expect(reply.name == "web")
        let processPane = try #require(reply.processPaneID)
        #expect(fixture.processStatusPanes.map(\.id) == [processPane])
        #expect(fixture.processTarget(processPane) == .pinned(FakeProcessTable.listener))
        #expect(splitDirection(between: caller, and: processPane, in: fixture.session.tree.root) == .horizontal)
        #expect(fixture.session.tree.focusedPaneID == caller)
    }

    @Test func repeatedShareReusesTheEntryAndTheProcessStatusPane() async throws {
        let fixture = ServerStoreFixture()
        fixture.scanner.listener = FakeProcessTable.listener
        let first = try await fixture.share()
        let second = try await fixture.share()
        #expect(second.entry === first.entry)
        #expect(!second.created)
        #expect(fixture.processStatusPanes.count == 1)
        #expect(fixture.store.serverReply(second).processPaneID == fixture.store.serverReply(first).processPaneID)
    }

    @Test func shareWithNoProcessViewOpensNoPane() async throws {
        let fixture = ServerStoreFixture()
        fixture.scanner.listener = FakeProcessTable.listener
        let count = fixture.session.tree.allPanes.count
        let result = try await fixture.share(processView: false)
        #expect(fixture.session.tree.allPanes.count == count)
        #expect(fixture.store.serverReply(result).processPaneID == nil)
    }

    @Test func shareAfterTheProcessStatusPaneWasClosedOpensANewOne() async throws {
        let fixture = ServerStoreFixture()
        fixture.scanner.listener = FakeProcessTable.listener
        let first = try #require(fixture.store.serverReply(try await fixture.share()).processPaneID)
        fixture.session.tree.removePane(id: first)
        #expect(fixture.processStatusPanes.isEmpty)
        let second = try #require(fixture.store.serverReply(try await fixture.share()).processPaneID)
        #expect(second != first)
        #expect(fixture.processStatusPanes.map(\.id) == [second])
    }

    @Test func shareOnAStartedPortReturnsTheManagedEntry() async throws {
        let fixture = ServerStoreFixture()
        let started = try fixture.start(processView: false)
        fixture.scanner.listener = FakeProcessTable.listener
        let shared = try await fixture.share()
        #expect(shared.entry === started.entry)
        #expect(!shared.created)
        #expect(shared.entry.backend.kind == .terminal)
    }

    @Test func stopRefusesASharedServer() async throws {
        let fixture = ServerStoreFixture()
        fixture.scanner.listener = FakeProcessTable.listener
        let entry = try await fixture.share().entry
        await entry.performTick()
        #expect(throws: ServerXPCError.notManaged) { try fixture.store.stopServerForXPC(ServerControlRequest(port: 8083)).get() }
        await entry.awaitPendingWork()
        #expect(fixture.signaller.sent.isEmpty)
        #expect(fixture.store.servers.entry(port: 8083) === entry)
    }

    @Test func restartRefusesASharedServer() async throws {
        let fixture = ServerStoreFixture()
        fixture.scanner.listener = FakeProcessTable.listener
        let entry = try await fixture.share().entry
        await entry.performTick()
        #expect(throws: ServerXPCError.notManaged) { try fixture.store.restartServerForXPC(ServerControlRequest(serverID: entry.id)).get() }
        await entry.awaitPendingWork()
        #expect(fixture.signaller.sent.isEmpty)
    }

    @Test func unshareRemovesASharedServerWithoutSignalling() async throws {
        let fixture = ServerStoreFixture()
        fixture.scanner.listener = FakeProcessTable.listener
        let shared = try await fixture.share()
        await shared.entry.performTick()
        let processPane = fixture.store.serverReply(shared).processPaneID
        let result = try fixture.store.unshareServerForXPC(ServerControlRequest(port: 8083)).get()
        #expect(result.entry === shared.entry)
        #expect(fixture.store.serverReply(result).state == .listening)
        #expect(fixture.store.servers.entries.isEmpty)
        #expect(fixture.signaller.sent.isEmpty)
        #expect(fixture.processStatusPanes.map(\.id) == processPane.map { [$0] })
    }

    @Test func unshareRefusesAStartedServer() throws {
        let fixture = ServerStoreFixture()
        let started = try fixture.start()
        #expect(throws: ServerXPCError.managedServer) { try fixture.store.unshareServerForXPC(ServerControlRequest(serverID: started.entry.id)).get() }
        #expect(fixture.store.servers.entries.count == 1)
    }

    @Test func unshareFromTheRowMenuRemovesOnlySharedServers() async throws {
        let fixture = ServerStoreFixture()
        let started = try fixture.start(port: 8083)
        fixture.scanner.listener = FakeProcessTable.listener
        let shared = try await fixture.share(port: 9000)
        fixture.store.unshareServer(started.entry)
        fixture.store.unshareServer(shared.entry)
        #expect(fixture.store.servers.entries.map(\.id) == [started.entry.id])
        #expect(fixture.signaller.sent.isEmpty)
    }

    @Test func startOnASharedPortThatStillListensFails() async throws {
        let fixture = ServerStoreFixture()
        fixture.scanner.listener = FakeProcessTable.listener
        let shared = try await fixture.share(processView: false)
        await shared.entry.performTick()
        let count = fixture.session.tree.allPanes.count
        #expect(throws: ServerXPCError.portShared(8083)) { try fixture.start() }
        #expect(shared.entry.backend.kind == .external)
        #expect(fixture.session.tree.allPanes.count == count)
        #expect(fixture.signaller.sent.isEmpty)
    }

    @Test func startOnASharedPortNoLongerListeningTakesItOver() async throws {
        let fixture = ServerStoreFixture()
        fixture.scanner.listener = FakeProcessTable.listener
        let shared = try await fixture.share(processView: false)
        fixture.scanner.listener = nil
        await shared.entry.performTick()
        let started = try fixture.start()
        #expect(started.entry === shared.entry)
        #expect(started.entry.backend.kind == .terminal)
        #expect(fixture.store.serverReply(started).terminalPaneID != nil)
        #expect(fixture.signaller.sent.isEmpty)
    }

    @Test func startOpensTheProcessStatusPaneOnceThePortListens() async throws {
        let fixture = ServerStoreFixture()
        let caller = fixture.callingPaneID
        let result = try fixture.start()
        let terminalID = try #require(fixture.store.serverReply(result).terminalPaneID)
        await result.entry.performTick()
        #expect(fixture.processStatusPanes.isEmpty)
        fixture.scanner.listener = FakeProcessTable.listener
        await result.entry.performTick()
        let processPane = try #require(fixture.processStatusPanes.first?.id)
        #expect(fixture.processStatusPanes.count == 1)
        #expect(fixture.processTarget(processPane) == .pinned(FakeProcessTable.listener))
        #expect(splitDirection(between: terminalID, and: processPane, in: fixture.session.tree.root) == .vertical)
        #expect(fixture.session.tree.focusedPaneID == caller)
        #expect(fixture.store.serverReply(result).processPaneID == processPane)
    }

    @Test func startWithNoProcessViewOpensNoPane() async throws {
        let fixture = ServerStoreFixture()
        let result = try fixture.start(processView: false)
        fixture.scanner.listener = FakeProcessTable.listener
        await result.entry.performTick()
        #expect(fixture.processStatusPanes.isEmpty)
    }

    @Test func restartRetargetsTheProcessStatusPaneToTheNewListener() async throws {
        let fixture = ServerStoreFixture()
        let result = try fixture.start()
        fixture.scanner.listener = FakeProcessTable.listener
        await result.entry.performTick()
        let processPane = try #require(fixture.processStatusPanes.first?.id)
        fixture.scanner.listener = 100_950
        await result.entry.performTick()
        #expect(fixture.processTarget(processPane) == .pinned(100_950))
        #expect(fixture.processStatusPanes.count == 1)
    }

    @Test func aClosedProcessStatusPaneIsNotReopenedOnTheNextListener() async throws {
        let fixture = ServerStoreFixture()
        let result = try fixture.start()
        fixture.scanner.listener = FakeProcessTable.listener
        await result.entry.performTick()
        let processPane = try #require(fixture.processStatusPanes.first?.id)
        fixture.session.tree.removePane(id: processPane)
        fixture.scanner.listener = 100_950
        await result.entry.performTick()
        #expect(fixture.processStatusPanes.isEmpty)
    }

    @Test func listReturnsEveryServerInRegistrationOrder() async throws {
        let fixture = ServerStoreFixture()
        let started = try fixture.start(port: 8083)
        fixture.scanner.listener = FakeProcessTable.listener
        let shared = try await fixture.share(port: 9000, name: "web")
        let reply = try fixture.store.listServersForXPC().get()
        #expect(reply.servers.map(\.serverID) == [started.entry.id, shared.entry.id])
        #expect(reply.servers.map(\.kind) == [.terminal, .external])
        #expect(reply.servers.map(\.port) == [8083, 9000])
        #expect(reply.servers[1].name == "web")
        #expect(reply.servers[0].terminalPaneID != nil)
        #expect(reply.servers[1].processPaneID != nil)
        #expect(reply.servers.allSatisfy { $0.tailnetURL == nil })
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

    @Test func everyVerbFailsWithFlagOff() async {
        let fixture = ServerStoreFixture(servers: false)
        #expect(throws: ServerXPCError.flagOff) { try fixture.start() }
        await #expect(throws: ServerXPCError.flagOff) { try await fixture.share() }
        #expect(throws: ServerXPCError.flagOff) { try fixture.store.listServersForXPC().get() }
        #expect(throws: ServerXPCError.flagOff) { try fixture.store.unshareServerForXPC(ServerControlRequest(port: 8083)).get() }
        #expect(throws: ServerXPCError.flagOff) { try fixture.store.stopServerForXPC(ServerControlRequest(port: 8083)).get() }
        #expect(throws: ServerXPCError.flagOff) { try fixture.store.restartServerForXPC(ServerControlRequest(port: 8083)).get() }
        await #expect(throws: ServerXPCError.flagOff) { try await fixture.store.tailnetServerForXPC(ServerTailnetRequest(port: 8083)).get() }
        #expect(fixture.tailscale.calls.isEmpty)
        #expect(fixture.session.tree.allPanes.count == 1)
        #expect(fixture.store.servers.entries.isEmpty)
    }
}

@MainActor
struct ServerTailnetVerbTests {
    @Test func tailnetVerbOnAnUnknownServerFails() async {
        let fixture = ServerStoreFixture()
        await #expect(throws: ServerXPCError.unknownServer) { try await fixture.store.tailnetServerForXPC(ServerTailnetRequest(port: 3000)).get() }
        #expect(fixture.tailscale.serveCalls.isEmpty)
    }

    @Test func shareWithTailnetSharesAfterRegistering() async throws {
        let fixture = ServerStoreFixture()
        fixture.scanner.listener = FakeProcessTable.listener
        let result = try await fixture.store.shareServerForXPC(ServerShareRequest(paneID: fixture.callingPaneID, port: 3000, processView: false, tailnet: true)).get()
        let reply = fixture.store.serverReply(result)
        #expect(reply.tailnetURL == "https://host.tailnet.ts.net:3000/")
        #expect(reply.tailnetError == nil)
        #expect(fixture.tailscale.serveCalls == [TailscaleArgs.serveOn(port: 3000)])
    }

    @Test func shareWithTailnetFailureKeepsTheShareAndReportsTheError() async throws {
        let fixture = ServerStoreFixture()
        fixture.tailscale.status = TailscaleFixtures.loggedOut
        fixture.scanner.listener = FakeProcessTable.listener
        let result = try await fixture.store.shareServerForXPC(ServerShareRequest(paneID: fixture.callingPaneID, port: 3000, processView: false, tailnet: true)).get()
        let reply = fixture.store.serverReply(result)
        #expect(fixture.store.servers.entries.map(\.id) == [result.entry.id])
        #expect(reply.tailnetURL == nil)
        #expect(reply.tailnetError == TailnetError.loggedOut.message)
    }

    @Test func listIncludesTheTailnetURL() async throws {
        let fixture = ServerStoreFixture()
        fixture.scanner.listener = FakeProcessTable.listener
        _ = try await fixture.share(port: 3000, processView: false)
        _ = try await fixture.store.tailnetServerForXPC(ServerTailnetRequest(port: 3000)).get()
        let list = try fixture.store.listServersForXPC().get()
        #expect(list.servers.map(\.tailnetURL) == ["https://host.tailnet.ts.net:3000/"])
    }

    @Test func tailnetOffOnAServerNotSharedIsANoOp() async throws {
        let fixture = ServerStoreFixture()
        fixture.scanner.listener = FakeProcessTable.listener
        _ = try await fixture.share(port: 3000, processView: false)
        let result = try await fixture.store.tailnetServerForXPC(ServerTailnetRequest(port: 3000, off: true)).get()
        #expect(result.entry.tailnetURL == nil)
        #expect(fixture.tailscale.serveCalls.isEmpty)
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

    @Test func showTerminalIsANoOpForASharedServer() async throws {
        let fixture = ServerStoreFixture()
        let caller = fixture.callingPaneID
        fixture.scanner.listener = FakeProcessTable.listener
        let entry = try await fixture.share(processView: false).entry
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
    func anOutOfRangeWaitTimeoutIsRefusedBeforeStarting(_ seconds: Double) async throws {
        let fixture = ServerStoreFixture()
        let panesBefore = fixture.session.tree.allPanes.count
        let start = try JSONEncoder().encode(ServerStartRequest(paneID: fixture.callingPaneID, port: 8083, command: "go run .", workingDirectory: "/tmp", wait: true, waitTimeoutSeconds: seconds))
        let startResponse = await respond(fixture, verb: XPCVerb.serverStart, payload: start)
        #expect(!startResponse.ok)
        #expect(startResponse.error?.hasPrefix("wait timeout must be") == true)

        #expect(fixture.session.tree.allPanes.count == panesBefore)
    }

    @Test(arguments: [Double.infinity, -Double.infinity, Double.nan, 1e300])
    func firstStateLeavingStartingReturnsAtOnceForAnInvalidTimeout(_ seconds: Double) async throws {
        let fixture = ServerStoreFixture()
        let content = try fixture.start().entry
        #expect(await AppXPCService.firstStateLeavingStarting(content, clock: fixture.clock, timeout: seconds) == nil)
    }

    @Test func serverListReplyListsTheServers() async throws {
        let fixture = ServerStoreFixture()
        let started = try fixture.start()
        let response = await respond(fixture, verb: XPCVerb.serverList, payload: nil)
        #expect(response.ok)
        let reply = try JSONDecoder().decode(ServerListReply.self, from: try #require(response.payload))
        #expect(reply.servers.map(\.serverID) == [started.entry.id])
    }

    @Test func serverShareOfANonListeningPortIsAFailure() async throws {
        let fixture = ServerStoreFixture()
        let payload = try JSONEncoder().encode(ServerShareRequest(paneID: fixture.callingPaneID, port: 8083))
        let response = await respond(fixture, verb: XPCVerb.serverShare, payload: payload)
        #expect(!response.ok)
        #expect(response.error == "nothing of yours is listening on 127.0.0.1:8083")
    }

    @Test func serverUnshareRepliesWithTheRemovedServer() async throws {
        let fixture = ServerStoreFixture()
        fixture.scanner.listener = FakeProcessTable.listener
        let shared = try await fixture.share(processView: false)
        let payload = try JSONEncoder().encode(ServerControlRequest(port: 8083))
        let response = await respond(fixture, verb: XPCVerb.serverUnshare, payload: payload)
        #expect(response.ok)
        let reply = try JSONDecoder().decode(ServerReply.self, from: try #require(response.payload))
        #expect(reply.serverID == shared.entry.id)
        #expect(fixture.store.servers.entries.isEmpty)
    }

    @Test func malformedPayloadIsAFailure() async {
        let fixture = ServerStoreFixture()
        let response = await respond(fixture, verb: XPCVerb.serverStart, payload: Data("{}".utf8))
        #expect(!response.ok)
        #expect(response.error == "malformed server start request")
    }
}
