// AppXPCServiceCommandWaitTests.swift

import Foundation
import Testing
@testable import BattyKit

@MainActor
private final class FakeTabFactory {
    var tabs: [FakeCommandWaitTab] = []
    var tabIDs: [UUID] = []
    private var waiters: [CheckedContinuation<FakeCommandWaitTab, Never>] = []

    func make(_ tab: TabRuntime) -> any CommandWaitTab {
        let fake = FakeCommandWaitTab()
        tabs.append(fake)
        tabIDs.append(tab.id)
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume(returning: fake) }
        return fake
    }

    /// The first fake, once the service has asked for it and armed it.
    func armedTab() async -> FakeCommandWaitTab {
        let fake: FakeCommandWaitTab
        if let first = tabs.first {
            fake = first
        } else {
            fake = await withCheckedContinuation { waiters.append($0) }
        }
        await fake.waitUntilArmed()
        return fake
    }
}

@MainActor
struct AppXPCServiceCommandWaitTests {
    private func makeService(
        _ store: AppStateStore,
        clock: TestClock = TestClock(),
        shell: String = "/bin/zsh",
        factory: FakeTabFactory,
        registry: AppXPCConnectionRegistry? = nil
    ) -> AppXPCService {
        AppXPCService(
            store: { store },
            clock: clock,
            connectionRegistry: registry,
            resolvedShell: { shell },
            commandWaitTab: { factory.make($0) }
        )
    }

    private func start(_ service: AppXPCService, verb: String, payload: some Encodable, connectionID: ObjectIdentifier? = nil) throws -> Task<XPCResponse, Never> {
        try start(service, verb: verb, payloadData: try JSONEncoder().encode(payload), connectionID: connectionID)
    }

    private func start(_ service: AppXPCService, verb: String, payloadData: Data, connectionID: ObjectIdentifier? = nil) throws -> Task<XPCResponse, Never> {
        let requestData = try JSONEncoder().encode(XPCRequest(verb: verb, payload: payloadData))
        return Task { @MainActor in
            let data: Data = await withCheckedContinuation { continuation in
                service.perform(requestData, connectionID: connectionID) { continuation.resume(returning: $0) }
            }
            return (try? JSONDecoder().decode(XPCResponse.self, from: data)) ?? XPCResponse(ok: false, error: "undecodable")
        }
    }

    private func tabNew(_ paneID: UUID, command: String? = "make test", wait: Bool? = true, timeout: Double? = nil) -> TabNewRequest {
        TabNewRequest(paneID: paneID, sourceTabID: nil, command: command, workingDirectory: nil, background: nil, wait: wait, waitTimeoutSeconds: timeout)
    }

    private func lines(_ tab: TabRuntime) -> [String] {
        tab.terminal.renderedConfig.split(separator: "\n").map(String.init)
    }

    @Test func tabNewWaitRefusesAnUnsupportedShellBeforeCreatingATab() async throws {
        let store = AppStateStore()
        let pane = store.sessions[0].focusedPaneAnyKind
        let before = pane.tabs.count
        let factory = FakeTabFactory()
        let response = try await start(makeService(store, shell: "/opt/homebrew/bin/fish", factory: factory), verb: XPCVerb.tabNew, payload: tabNew(pane.id)).value
        #expect(response.ok == false)
        #expect(response.error?.contains("shell integration") == true)
        #expect(response.error?.contains("fish") == true)
        #expect(pane.tabs.count == before)
        #expect(factory.tabs.isEmpty)
    }

    @Test func paneSplitWaitRefusesAnUnsupportedShellBeforeSplitting() async throws {
        let store = AppStateStore()
        let session = store.sessions[0]
        let before = session.tree.allPanes.count
        let request = PaneSplitRequest(paneID: session.focusedPaneAnyKind.id, direction: .horizontal, command: "make test", wait: true)
        let response = try await start(makeService(store, shell: "/bin/sh", factory: FakeTabFactory()), verb: XPCVerb.paneSplit, payload: request).value
        #expect(response.ok == false)
        #expect(response.error?.contains("shell integration") == true)
        #expect(session.tree.allPanes.count == before)
    }

    @Test func tabNewWaitRefusesAHiddenPane() async throws {
        let store = AppStateStore()
        let pane = store.sessions[0].focusedPaneAnyKind
        pane.isHidden = true
        let before = pane.tabs.count
        let response = try await start(makeService(store, factory: FakeTabFactory()), verb: XPCVerb.tabNew, payload: tabNew(pane.id)).value
        #expect(response.ok == false)
        #expect(response.error?.contains("hidden") == true)
        #expect(pane.tabs.count == before)
    }

    @Test func waitRefusesAMultiLineCommand() async throws {
        let store = AppStateStore()
        let pane = store.sessions[0].focusedPaneAnyKind
        let before = pane.tabs.count
        let response = try await start(makeService(store, factory: FakeTabFactory()), verb: XPCVerb.tabNew, payload: tabNew(pane.id, command: "a\nb")).value
        #expect(response.ok == false)
        #expect(response.error == "--wait needs a single-line command")
        #expect(pane.tabs.count == before)
    }

    @Test func waitWithoutACommandFails() async throws {
        let store = AppStateStore()
        let pane = store.sessions[0].focusedPaneAnyKind
        let response = try await start(makeService(store, factory: FakeTabFactory()), verb: XPCVerb.tabNew, payload: tabNew(pane.id, command: nil)).value
        #expect(response.ok == false)
        #expect(response.error == "--wait needs a command")
    }

    /// Finite values decode, so they reach `WaitTimeout`; a non-finite one
    /// (sent as a string by a client using a non-conforming float strategy,
    /// since plain JSON cannot carry it) fails to decode. Either way nothing
    /// is created and nothing traps.
    @Test(arguments: [1e300, Double.greatestFiniteMagnitude, 0, -5, 86_401, Double.infinity, -Double.infinity, Double.nan])
    func aNonFiniteOrHugeTimeoutIsRefusedWithoutCrashing(_ seconds: Double) async throws {
        let store = AppStateStore()
        let session = store.sessions[0]
        let pane = session.focusedPaneAnyKind
        let tabsBefore = pane.tabs.count
        let panesBefore = session.tree.allPanes.count
        let factory = FakeTabFactory()
        let service = makeService(store, factory: factory)
        let encoder = JSONEncoder()
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        let expected = seconds.isFinite ? "wait timeout must be" : "malformed"

        let tabResponse = try await start(service, verb: XPCVerb.tabNew, payloadData: try encoder.encode(tabNew(pane.id, timeout: seconds))).value
        #expect(tabResponse.ok == false)
        #expect(tabResponse.error?.hasPrefix(expected) == true, "\(tabResponse.error ?? "nil")")

        let split = PaneSplitRequest(paneID: pane.id, direction: .horizontal, command: "make test", wait: true, waitTimeoutSeconds: seconds)
        let splitResponse = try await start(service, verb: XPCVerb.paneSplit, payloadData: try encoder.encode(split)).value
        #expect(splitResponse.ok == false)
        #expect(splitResponse.error?.hasPrefix(expected) == true, "\(splitResponse.error ?? "nil")")

        #expect(pane.tabs.count == tabsBefore)
        #expect(session.tree.allPanes.count == panesBefore)
        #expect(factory.tabs.isEmpty)
    }

    @Test func tabNewWaitTypesTheCommandIntoAShellTab() async throws {
        let store = AppStateStore()
        let pane = store.sessions[0].focusedPaneAnyKind
        let factory = FakeTabFactory()
        let task = try start(makeService(store, factory: factory), verb: XPCVerb.tabNew, payload: tabNew(pane.id))
        let fake = await factory.armedTab()
        #expect(fake.armed == "make test")
        let tab = try #require(pane.tabs.first { $0.id == factory.tabIDs.first })
        #expect(!lines(tab).contains("wait-after-command = true"))
        fake.fireWillType()
        fake.fireFinished(0, 0)
        #expect(await task.value.ok == true)
    }

    @Test func tabNewWaitRepliesWithExitCodeAndDuration() async throws {
        let store = AppStateStore()
        let session = store.sessions[0]
        let pane = session.focusedPaneAnyKind
        let factory = FakeTabFactory()
        let task = try start(makeService(store, factory: factory), verb: XPCVerb.tabNew, payload: tabNew(pane.id))
        let fake = await factory.armedTab()
        fake.fireWillType()
        fake.fireFinished(3, 1_500_000_000)
        let response = await task.value
        #expect(response.ok == true)
        let reply = try JSONDecoder().decode(TabNewReply.self, from: try #require(response.payload))
        #expect(reply.exitCode == 3)
        #expect(reply.durationMs == 1500)
        #expect(reply.waitResult == .exited)
        #expect(reply.sessionID == session.id)
        #expect(reply.paneID == pane.id)
        #expect(reply.tabID == factory.tabIDs.first)
    }

    @Test func paneSplitWaitRepliesWithTabIDAndExitCode() async throws {
        let store = AppStateStore()
        let session = store.sessions[0]
        let factory = FakeTabFactory()
        let request = PaneSplitRequest(paneID: session.focusedPaneAnyKind.id, direction: .vertical, command: "make test", wait: true)
        let task = try start(makeService(store, factory: factory), verb: XPCVerb.paneSplit, payload: request)
        let fake = await factory.armedTab()
        fake.fireWillType()
        fake.fireFinished(0, 2_000_000)
        let response = await task.value
        #expect(response.ok == true)
        let reply = try JSONDecoder().decode(PaneSplitReply.self, from: try #require(response.payload))
        #expect(reply.created == true)
        #expect(reply.tabID == factory.tabIDs.first)
        #expect(reply.exitCode == 0)
        #expect(reply.durationMs == 2)
        #expect(reply.waitResult == .exited)
        let newPane = try #require(session.tree.allPanes.first { $0.id == reply.paneID })
        #expect(newPane.tabs.first?.id == reply.tabID)
    }

    @Test func tabNewWaitTimesOutOnTheInjectedClock() async throws {
        let store = AppStateStore()
        let pane = store.sessions[0].focusedPaneAnyKind
        let clock = TestClock()
        let factory = FakeTabFactory()
        let task = try start(makeService(store, clock: clock, factory: factory), verb: XPCVerb.tabNew, payload: tabNew(pane.id, timeout: 5))
        let fake = await factory.armedTab()
        fake.fireWillType()
        #expect(await clock.waitForSleepers(1))
        await clock.advance(by: .seconds(5))
        let response = await task.value
        #expect(response.ok == true)
        let reply = try JSONDecoder().decode(TabNewReply.self, from: try #require(response.payload))
        #expect(reply.waitResult == .timedOut)
        #expect(reply.exitCode == nil)
        #expect(reply.tabID == factory.tabIDs.first)
    }

    @Test func waitEndsWhenTheClientDisconnects() async throws {
        let store = AppStateStore()
        let pane = store.sessions[0].focusedPaneAnyKind
        let registry = AppXPCConnectionRegistry()
        let connection = NSXPCConnection(listenerEndpoint: NSXPCListener.anonymous().endpoint)
        registry.register(connection)
        let factory = FakeTabFactory()
        let task = try start(makeService(store, factory: factory, registry: registry), verb: XPCVerb.tabNew, payload: tabNew(pane.id), connectionID: ObjectIdentifier(connection))
        let fake = await factory.armedTab()
        fake.fireWillType()
        registry.unregister(id: ObjectIdentifier(connection))
        let response = await task.value
        #expect(response.ok == false)
        #expect(response.error == "wait cancelled: client disconnected")
        #expect(fake.finishedObserverCount == 0)
        #expect(fake.closedObserverCount == 0)
        #expect(fake.armCount == 1)
    }

    @Test func paneSplitWithoutWaitRepliesWithTheNewTabID() async throws {
        let store = AppStateStore()
        let session = store.sessions[0]
        let request = PaneSplitRequest(paneID: session.focusedPaneAnyKind.id, direction: .horizontal)
        let response = try await start(makeService(store, factory: FakeTabFactory()), verb: XPCVerb.paneSplit, payload: request).value
        let reply = try JSONDecoder().decode(PaneSplitReply.self, from: try #require(response.payload))
        let newPane = try #require(session.tree.allPanes.first { $0.id == reply.paneID })
        #expect(reply.tabID != nil)
        #expect(reply.tabID == newPane.tabs.first?.id)
        #expect(reply.waitResult == nil)
    }

    @Test func tabNewWithoutWaitStillRunsTheCommandInPlaceOfTheShell() async throws {
        let store = AppStateStore()
        let pane = store.sessions[0].focusedPaneAnyKind
        let factory = FakeTabFactory()
        let response = try await start(makeService(store, factory: factory), verb: XPCVerb.tabNew, payload: tabNew(pane.id, wait: nil)).value
        let reply = try JSONDecoder().decode(TabNewReply.self, from: try #require(response.payload))
        let tab = try #require(pane.tabs.first { $0.id == reply.tabID })
        #expect(lines(tab).contains("wait-after-command = true"))
        #expect(factory.tabs.isEmpty)
        #expect(reply.waitResult == nil)
    }
}
