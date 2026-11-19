// InAppStaticServerTests.swift

import BattyXPCCore
import Foundation
import os
import Testing
@testable import BattyKit

/// A server that never binds. `start` can be held open on a gate so a test
/// can act while the store is suspended in the bind.
nonisolated final class FakeStaticServer: StaticServing, @unchecked Sendable {
    private let lock = NSLock()
    var result: Result<UInt16, StaticServerError>
    private(set) var requestedPorts: [UInt16?] = []
    private(set) var stopCount = 0
    private(set) var broadcasts = 0
    /// `start`, `stop` and `wait` in call order, so a test can check that a
    /// restart awaited the release before binding again.
    private(set) var calls: [String] = []
    var stats = StaticServerStats()
    var gate: AsyncGate?
    var releaseGate: AsyncGate?

    init(result: Result<UInt16, StaticServerError> = .success(52144)) {
        self.result = result
    }

    func start(port: UInt16?) async throws(StaticServerError) -> UInt16 {
        lock.withLock { requestedPorts.append(port); calls.append("start") }
        if let gate { await gate.enterAndWait() }
        return try lock.withLock { result }.get()
    }

    func stop() { lock.withLock { stopCount += 1; calls.append("stop") } }

    func waitUntilStopped() async {
        if let releaseGate { await releaseGate.enterAndWait() }
        lock.withLock { calls.append("wait") }
    }
    func broadcastReload() { lock.withLock { broadcasts += 1 } }
}

/// Lets a test learn that `start` was entered, then release it.
nonisolated final class AsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var entered: CheckedContinuation<Void, Never>?
    private var didEnter = false
    private var release: CheckedContinuation<Void, Never>?
    private var released = false

    func enterAndWait() async {
        let waiter: CheckedContinuation<Void, Never>? = lock.withLock {
            didEnter = true
            defer { entered = nil }
            return entered
        }
        waiter?.resume()
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock { () -> Bool in
                if released { return true }
                release = continuation
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func waitUntilEntered() async {
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock { () -> Bool in
                if didEnter { return true }
                entered = continuation
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func open() {
        let waiter: CheckedContinuation<Void, Never>? = lock.withLock {
            released = true
            defer { release = nil }
            return release
        }
        waiter?.resume()
    }
}

nonisolated final class FakeDirectoryWatcher: DirectoryChangeWatching, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable ([String]) -> Void)?
    private(set) var stopCount = 0

    func start(onChange: @escaping @Sendable ([String]) -> Void) { lock.withLock { handler = onChange } }
    func stop() { lock.withLock { stopCount += 1; handler = nil } }
    var isWatching: Bool { lock.withLock { handler != nil } }
    func fire(_ paths: [String] = ["/x"]) { lock.withLock { handler }?(paths) }
}

@MainActor
final class FakeInProcessBackend: InProcessServerBackend {
    var isServing = true
    var stopServingCount = 0
    var resumeResult: Result<Void, StaticServerError> = .success(())
    var facts = ServingFacts(root: "/tmp/site", requestCount: 0, reloadClientCount: 0, lastChangeAt: nil, injectsReloadScript: true)

    var kind: ServerBackendKind { .inApp }
    var canRestart: Bool { true }
    var canStop: Bool { true }
    var stopsOnTearDown: Bool { true }
    var command: String? { nil }
    var workingDirectory: String? { "/tmp/site" }
    var isAvailable: Bool { true }
    var servingFacts: ServingFacts { facts }
    func start(events: @escaping (ServerBackendEvent) -> Void) {}
    func rerun() -> Bool { false }
    func detach() {}
    func stopDecision(listenerPid: pid_t?, table: ProcessTableReading) -> ServerStopDecision { .nothing }
    func stopServing() {
        stopServingCount += 1
        isServing = false
    }
    func resumeServing() async throws(StaticServerError) {
        try resumeResult.get()
        isServing = true
    }
}

@MainActor
struct InAppServerPaneContentTests {
    let clock = TestClock()
    let scanner = FakePortScanner()
    let probe = FakeHTTPProbe()
    let fetcher = FakeStatsFetcher()
    let signaller = FakeProcessSignaller()
    let backend = FakeInProcessBackend()

    func content() -> ServerPaneContent {
        ServerPaneContent(
            port: 52144, url: URL(string: "http://127.0.0.1:52144/"), backend: backend, clock: clock, scanner: scanner,
            probe: probe, statsFetcher: fetcher, metricsProvider: { _ in Issue.record("sampled metrics"); return nil },
            commandLineProvider: { _ in nil }, signaller: signaller, processTable: FakeProcessTable(tabID: UUID()), opener: { _ in }
        )
    }

    func active(_ content: ServerPaneContent) async {
        content.setUp(visible: true)
        await clock.waitForSleepers(1)
    }

    @Test func inAppServerIsServingWithoutScanningProbingOrStats() async {
        let content = content()
        await active(content)
        await content.performTick()
        #expect(content.state == .listening(pid: nil))
        #expect(scanner.scans == 0)
        #expect(probe.probes == 0)
        #expect(fetcher.fetches.isEmpty)
        #expect(ServerPaneDisplay.stateText(content.state, isResponding: content.isResponding, kind: .inApp) == "Serving")
        content.tearDown()
    }

    @Test func inAppStopStopsServingAndShowsStopped() async {
        let content = content()
        await active(content)
        await content.performTick()
        #expect(content.canStop)
        #expect(await content.performStop())
        #expect(backend.stopServingCount == 1)
        #expect(content.state == .stopped(exitCode: nil, reason: .requested))
        content.tearDown()
    }

    @Test func inAppTearDownStopsServingSynchronously() async {
        let content = content()
        await active(content)
        content.tearDown()
        #expect(backend.stopServingCount == 1)
        #expect(!backend.isServing)
    }

    @Test func inAppRestartResumesTheSamePort() async {
        let content = content()
        await active(content)
        await content.performTick()
        await content.performStop()
        await content.performRestart()
        #expect(backend.isServing)
        #expect(content.state == .starting)
        await content.performTick()
        #expect(content.state == .listening(pid: nil))
        #expect(content.lastError == nil)
        content.tearDown()
    }

    @Test func inAppRestartOnABusyPortStaysStoppedWithError() async {
        let content = content()
        await active(content)
        await content.performTick()
        await content.performStop()
        backend.resumeResult = .failure(.portInUse(52144))
        await content.performRestart()
        #expect(content.state == .stopped(exitCode: nil, reason: .requested))
        #expect(content.lastError == "port 52144 is in use")
        content.tearDown()
    }

    @Test func inAppNeverSignalsAProcess() async {
        let content = content()
        await active(content)
        await content.performTick()
        await content.performStop()
        await content.performRestart()
        content.tearDown()
        await content.awaitPendingWork()
        #expect(signaller.sent.isEmpty)
    }

    @Test func servingFactsUpdateOnTheTickOnlyWhileVisible() async {
        let content = content()
        await active(content)
        backend.facts.requestCount = 3
        await content.performTick()
        #expect(content.servingFacts?.requestCount == 3)
        content.setVisible(false)
        backend.facts.requestCount = 9
        await content.performTick()
        #expect(content.servingFacts?.requestCount == 3)
        content.tearDown()
    }
}

@MainActor
struct InAppStaticServerBackendTests {
    let clock = TestClock()
    let server = FakeStaticServer()
    let watcher = FakeDirectoryWatcher()

    func backend() throws -> InAppStaticServerBackend {
        let resolver = try #require(StaticFilePathResolver(root: FileManager.default.temporaryDirectory))
        let server = server, watcher = watcher
        return InAppStaticServerBackend(resolver: resolver, injectsReloadScript: true, clock: clock, makeServer: { _, _ in server }, makeWatcher: { _ in watcher })
    }

    @Test func changeFromTheWatcherReachesBroadcasterAfterDebounce() async throws {
        let backend = try backend()
        try await backend.startServing(port: nil)
        var observed = 0
        backend.broadcaster.addObserver { observed += 1 }
        watcher.fire()
        #expect(await clock.waitForSleepers(1))
        await clock.advance(by: .milliseconds(150))
        await backend.pendingReload?.value
        #expect(observed == 1)
        #expect(server.broadcasts == 1)
        #expect(backend.servingFacts.lastChangeAt != nil)
        backend.stopServing()
    }

    @Test func stopServingStopsTheWatcher() async throws {
        let backend = try backend()
        try await backend.startServing(port: nil)
        #expect(watcher.isWatching)
        backend.stopServing()
        #expect(!watcher.isWatching)
        #expect(server.stopCount == 1)
        #expect(!backend.isServing)
    }

    @Test func resumeServingRebindsTheSamePort() async throws {
        let backend = try backend()
        let port = try await backend.startServing(port: nil)
        backend.stopServing()
        try await backend.resumeServing()
        #expect(server.requestedPorts == [nil, port])
        #expect(server.calls == ["start", "stop", "wait", "start"])
        #expect(backend.isServing)
        backend.stopServing()
    }

    @Test func resumeServingBindsOnlyAfterTheStoppedListenerIsReleased() async throws {
        let backend = try backend()
        try await backend.startServing(port: nil)
        let release = AsyncGate()
        server.releaseGate = release
        backend.stopServing()
        let resume = Task { try await backend.resumeServing() }
        await release.waitUntilEntered()
        #expect(server.calls == ["start", "stop"])
        #expect(!backend.isServing)
        release.open()
        try await resume.value
        #expect(server.calls == ["start", "stop", "wait", "start"])
        #expect(backend.isServing)
        backend.stopServing()
    }
}

/// The in-app backend on a real loopback listener: Restart must rebind the
/// port the stopped listener held, not race its release.
@MainActor
struct InAppStaticServerRealSocketTests {
    private func get(_ port: UInt16) async -> RawHTTPResponse? {
        await boundedValue { await RawHTTPTestClient.send(RawHTTPTestClient.get("/", port: port), port: port) } ?? nil
    }

    private func freePort(_ fixture: StaticServerFixture) async throws -> UInt16 {
        let probe = StaticFileServer(resolver: try #require(StaticFilePathResolver(root: fixture.root)), injectsReloadScript: false)
        defer { probe.stop() }
        let result = await boundedValue { () -> Result<UInt16, StaticServerError> in
            do throws(StaticServerError) { return .success(try await probe.start(port: nil)) } catch { return .failure(error) }
        }
        let port = try #require(result).get()
        probe.stop()
        #expect(await awaitBounded { await probe.waitUntilStopped() })
        return port
    }

    private func backend(_ fixture: StaticServerFixture) throws -> InAppStaticServerBackend {
        InAppStaticServerBackend(
            resolver: try #require(StaticFilePathResolver(root: fixture.root)), injectsReloadScript: false,
            clock: TestClock(), makeWatcher: { _ in FakeDirectoryWatcher() })
    }

    private func serve(_ backend: InAppStaticServerBackend, port: UInt16) async throws -> UInt16 {
        let result = await boundedValue { @MainActor () -> Result<UInt16, StaticServerError> in
            do throws(StaticServerError) { return .success(try await backend.startServing(port: port)) } catch { return .failure(error) }
        }
        return try #require(result).get()
    }

    @Test func stopThenResumeRebindsTheSameFixedPortAndServes() async throws {
        let fixture = try StaticServerFixture()
        defer { fixture.remove() }
        let port = try await freePort(fixture)
        let backend = try backend(fixture)
        defer { backend.stopServing() }
        #expect(try await serve(backend, port: port) == port)
        #expect(await get(port)?.status == 200)
        backend.stopServing()
        let resumed = await boundedValue { @MainActor () -> StaticServerError? in
            do throws(StaticServerError) { try await backend.resumeServing(); return nil } catch { return error }
        }
        #expect(resumed == .some(nil))
        #expect(backend.isServing)
        #expect(backend.port == port)
        let response = try #require(await get(port))
        #expect(response.status == 200)
        #expect(response.bodyText.contains("<h1>index</h1>"))
    }

    @Test func serverPaneRestartOfARunningServerServesAgain() async throws {
        let fixture = try StaticServerFixture()
        defer { fixture.remove() }
        let port = try await freePort(fixture)
        let backend = try backend(fixture)
        #expect(try await serve(backend, port: port) == port)
        let clock = TestClock()
        let content = ServerPaneContent(
            port: port, url: URL(string: "http://127.0.0.1:\(port)/"), backend: backend, clock: clock,
            scanner: FakePortScanner(), probe: FakeHTTPProbe(), statsFetcher: FakeStatsFetcher(),
            metricsProvider: { _ in nil }, commandLineProvider: { _ in nil }, signaller: FakeProcessSignaller(),
            processTable: FakeProcessTable(tabID: UUID()), opener: { _ in })
        defer { content.tearDown() }
        content.setUp(visible: true)
        #expect(await clock.waitForSleepers(1))
        await content.performTick()
        #expect(content.state == .listening(pid: nil))
        content.restart()
        #expect(await awaitBounded { @MainActor in await content.awaitPendingWork() })
        #expect(content.lastError == nil)
        #expect(content.state == .starting)
        #expect(backend.isServing)
        #expect(backend.port == port)
        let response = try #require(await get(port))
        #expect(response.status == 200)
        #expect(response.bodyText.contains("<h1>index</h1>"))
    }
}

/// A store whose in-app servers are fakes that never bind.
@MainActor
final class StaticServerStoreFixture {
    let base: ServerStoreFixture
    let root: URL
    var servers: [FakeStaticServer] = []
    var nextResult: Result<UInt16, StaticServerError> = .success(52144)
    var nextGate: AsyncGate?

    init(serverPane: Bool = true) throws {
        base = ServerStoreFixture(serverPane: serverPane)
        root = FileManager.default.temporaryDirectory.appendingPathComponent("serve-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let clock = base.clock
        base.store.makeInAppServerBackend = { [unowned self] resolver, injects in
            InAppStaticServerBackend(
                resolver: resolver, injectsReloadScript: injects, clock: clock,
                makeServer: { [unowned self] _, _ in
                    let server = FakeStaticServer(result: self.nextResult)
                    server.gate = self.nextGate
                    self.servers.append(server)
                    return server
                },
                makeWatcher: { _ in FakeDirectoryWatcher() })
        }
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    var store: AppStateStore { base.store }
    var session: SessionRuntime { base.session }
    var callingPaneID: UUID { base.callingPaneID }

    func serve(root: String? = nil, port: Int? = nil, inject: Bool? = nil, paneID: UUID? = nil, open: Bool? = nil) async -> Result<ServerXPCResult, ServerXPCError> {
        await store.serveStaticForXPC(ServerServeRequest(paneID: paneID ?? callingPaneID, root: root ?? self.root.path, port: port, open: open, inject: inject))
    }

    func backend(_ result: ServerXPCResult) -> InAppStaticServerBackend? {
        result.content.backend as? InAppStaticServerBackend
    }
}

@MainActor
func serveError(_ result: Result<ServerXPCResult, ServerXPCError>) -> ServerXPCError? {
    if case .failure(let error) = result { return error }
    return nil
}

@MainActor
struct AppStateStoreStaticServerTests {
    @Test func serveCreatesAServerPaneWithAnInAppBackend() async throws {
        let fixture = try StaticServerStoreFixture()
        let result = try await fixture.serve().get()
        #expect(result.created)
        #expect(fixture.base.pane(result.paneID)?.kind == .server)
        #expect(result.content.url.absoluteString == "http://127.0.0.1:52144/")
        let backend = try #require(fixture.backend(result))
        #expect(backend.isServing)
        #expect(backend.root == StaticFilePathResolver.realPath(fixture.root.path))
        let reply = fixture.store.serverReply(result)
        #expect(reply.root == backend.root)
        #expect(reply.state == .listening)
    }

    @Test func serveKeepsFocusOnTheCallingPane() async throws {
        let fixture = try StaticServerStoreFixture()
        let caller = fixture.callingPaneID
        _ = try await fixture.serve().get()
        #expect(fixture.session.tree.focusedPaneID == caller)
    }

    @Test func serveTwiceOnTheSameRootReusesThePane() async throws {
        let fixture = try StaticServerStoreFixture()
        let first = try await fixture.serve().get()
        let second = try await fixture.serve().get()
        #expect(!second.created)
        #expect(second.paneID == first.paneID)
        #expect(fixture.servers.count == 1)
    }

    @Test func serveOnAStoppedRootResumesIt() async throws {
        let fixture = try StaticServerStoreFixture()
        let first = try await fixture.serve().get()
        _ = fixture.store.stopServerForXPC(ServerControlRequest(paneID: fixture.callingPaneID, port: 52144))
        await first.content.awaitPendingWork()
        #expect(fixture.backend(first)?.isServing == false)
        let second = try await fixture.serve().get()
        #expect(second.paneID == first.paneID)
        #expect(fixture.backend(second)?.isServing == true)
        #expect(fixture.servers.last?.requestedPorts == [52144])
    }

    @Test func serveSameRootWithADifferentPortFails() async throws {
        let fixture = try StaticServerStoreFixture()
        _ = try await fixture.serve().get()
        let result = await fixture.serve(port: 9000)
        guard case .failure(.alreadyServing(_, let port)) = result else {
            Issue.record("expected alreadyServing, got \(result)")
            return
        }
        #expect(port == 52144)
    }

    @Test func serveANonDirectoryFails() async throws {
        let fixture = try StaticServerStoreFixture()
        let file = fixture.root.appendingPathComponent("file.txt")
        try Data().write(to: file)
        #expect(serveError(await fixture.serve(root: file.path)) == .notADirectory(file.path))
        #expect(serveError(await fixture.serve(root: fixture.root.path + "/missing")) == .notADirectory(fixture.root.path + "/missing"))
        #expect(fixture.servers.isEmpty)
    }

    @Test func serveABusyPortFails() async throws {
        let fixture = try StaticServerStoreFixture()
        fixture.nextResult = .failure(.portInUse(8000))
        #expect(serveError(await fixture.serve(port: 8000)) == .portInUse(8000))
        #expect(fixture.session.tree.allPanes.count == 1)
    }

    @Test func callingPaneClosedDuringBindStopsTheServerAndFails() async throws {
        let fixture = try StaticServerStoreFixture()
        let gate = AsyncGate()
        fixture.nextGate = gate
        let caller = fixture.callingPaneID
        let sibling = fixture.store.splitPane(id: caller, direction: .horizontal)
        #expect(sibling != nil)
        let task = Task { await fixture.serve(paneID: caller) }
        #expect(await awaitBounded { await gate.waitUntilEntered() })
        #expect(fixture.store.closePane(id: caller) == .closed)
        gate.open()
        let result = await task.value
        #expect(serveError(result) == .unknownPane)
        #expect(fixture.servers.first?.stopCount == 1)
    }

    @Test func closingTheServerPaneStopsServing() async throws {
        let fixture = try StaticServerStoreFixture()
        let result = try await fixture.serve().get()
        _ = fixture.store.closePane(id: result.paneID)
        #expect(fixture.backend(result)?.isServing == false)
        #expect(fixture.servers.first?.stopCount == 1)
    }

    @Test func stopAndRestartResolveTheInAppPaneByPort() async throws {
        let fixture = try StaticServerStoreFixture()
        let result = try await fixture.serve().get()
        let stopped = try fixture.store.stopServerForXPC(ServerControlRequest(paneID: fixture.callingPaneID, port: 52144)).get()
        #expect(stopped.paneID == result.paneID)
        await result.content.awaitPendingWork()
        #expect(fixture.backend(result)?.isServing == false)
        _ = try fixture.store.restartServerForXPC(ServerControlRequest(paneID: fixture.callingPaneID, port: 52144)).get()
        await result.content.awaitPendingWork()
        #expect(fixture.backend(result)?.isServing == true)
        #expect(fixture.base.signaller.sent.isEmpty)
    }

    @Test func serveFailsWithFlagOff() async throws {
        let fixture = try StaticServerStoreFixture(serverPane: false)
        #expect(serveError(await fixture.serve()) == .flagOff)
        #expect(fixture.servers.isEmpty)
    }

    @Test func serverStartOnAnInAppPortFails() async throws {
        let fixture = try StaticServerStoreFixture()
        _ = try await fixture.serve().get()
        guard case .failure(.alreadyServing) = fixture.store.startServerForXPC(ServerStartRequest(paneID: fixture.callingPaneID, port: 52144, command: "x", workingDirectory: "/tmp")) else {
            Issue.record("expected alreadyServing")
            return
        }
    }

    final class BrowserRecorder {
        var opened: [URL] = []
    }

    func recordingFixture() throws -> (StaticServerStoreFixture, BrowserRecorder) {
        let fixture = try StaticServerStoreFixture()
        let recorder = BrowserRecorder()
        fixture.store.openURLInBrowser = { recorder.opened.append($0) }
        return (fixture, recorder)
    }

    @Test func serveOpenOpensTheServedURLInTheDefaultBrowser() async throws {
        let (fixture, recorder) = try recordingFixture()
        let result = try await fixture.serve(open: true).get()
        #expect(recorder.opened == [result.content.url])
        #expect(Set(fixture.session.tree.allPanes.map(\.id)) == [fixture.callingPaneID, result.paneID])
    }

    @Test func serveWithoutOpenOpensNothing() async throws {
        let (fixture, recorder) = try recordingFixture()
        _ = try await fixture.serve().get()
        #expect(recorder.opened.isEmpty)
    }

    @Test func serveOpenOnAReusedServerOpensTheBrowserAgain() async throws {
        let (fixture, recorder) = try recordingFixture()
        let first = try await fixture.serve(open: true).get()
        let second = try await fixture.serve(open: true).get()
        #expect(!second.created)
        #expect(recorder.opened == [first.content.url, first.content.url])
    }

    @Test func staleServedSiteOpenTargetIsIgnored() async throws {
        let (fixture, recorder) = try recordingFixture()
        fixture.base.defaults.set("batty", forKey: "co.sstools.Batty.servedSiteOpenTarget")
        let result = try await fixture.serve(open: true).get()
        #expect(recorder.opened == [result.content.url])
        #expect(fixture.session.tree.allPanes.count == 2)
    }
}

@MainActor
struct AppXPCServiceStaticServerTests {
    @Test func serveReplyCarriesURLRootAndPane() async throws {
        let fixture = try StaticServerStoreFixture()
        let payload = try JSONEncoder().encode(ServerServeRequest(paneID: fixture.callingPaneID, root: fixture.root.path))
        let response = await AppXPCService.serverResponse(verb: XPCVerb.serverServe, payload: payload, store: fixture.store, clock: fixture.base.clock)
        #expect(response.ok)
        let reply = try JSONDecoder().decode(ServerReply.self, from: try #require(response.payload))
        #expect(reply.url == "http://127.0.0.1:52144/")
        #expect(reply.root == StaticFilePathResolver.realPath(fixture.root.path))
        #expect(fixture.base.pane(reply.paneID)?.kind == .server)
    }

    @Test func malformedServeIsAFailure() async throws {
        let fixture = try StaticServerStoreFixture()
        let response = await AppXPCService.serverResponse(verb: XPCVerb.serverServe, payload: Data("{}".utf8), store: fixture.store, clock: fixture.base.clock)
        #expect(!response.ok)
        #expect(response.error == "malformed server serve request")
    }
}

@MainActor
struct ServerPaneInAppDisplayTests {
    @Test func inAppListeningReadsServing() {
        #expect(ServerPaneDisplay.stateText(.listening(pid: nil), isResponding: nil, kind: .inApp) == "Serving")
        #expect(ServerPaneDisplay.stateText(.stopped(exitCode: nil, reason: .requested), isResponding: nil, kind: .inApp) == "Stopped")
    }

    @Test func stopShownForInAppListening() {
        #expect(ServerPaneDisplay.showsStop(.listening(pid: nil), canStop: true, kind: .inApp))
        #expect(!ServerPaneDisplay.showsStop(.listening(pid: nil), canStop: true, kind: .external))
    }
}
