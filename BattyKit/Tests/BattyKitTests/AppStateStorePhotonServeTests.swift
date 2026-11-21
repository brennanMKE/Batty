// AppStateStorePhotonServeTests.swift

import BattyXPCCore
import Foundation
import Testing
@testable import BattyKit

@MainActor
final class PhotonServeFixture {
    let base: StaticServerStoreFixture
    var photon: URL? = URL(fileURLWithPath: "/fake/bin/photon")
    var picks: [UInt16] = [52200]
    var searchPaths: [String?] = []

    init() throws {
        base = try StaticServerStoreFixture()
        base.store.locatePhoton = { [unowned self] path in
            self.searchPaths.append(path)
            return self.photon
        }
        base.store.pickServePort = { [unowned self] in
            self.picks.isEmpty ? nil : self.picks.removeFirst()
        }
    }

    var store: AppStateStore { base.store }
    var session: SessionRuntime { base.session }
    var rootPath: String { StaticFilePathResolver.realPath(base.root.path) ?? base.root.path }

    func serve(engine: ServeEngine? = nil, port: Int? = nil, open: Bool? = nil, searchPath: String? = nil) async -> Result<ServerXPCResult, ServerXPCError> {
        await store.serveStaticForXPC(ServerServeRequest(paneID: base.callingPaneID, root: base.root.path, port: port, open: open, engine: engine, searchPath: searchPath))
    }

    func command(_ result: ServerXPCResult) -> String? {
        (result.entry.backend as? TerminalTabServerBackend)?.command
    }

    func expectedCommand(port: UInt16) -> String {
        PhotonServeCommand.commandLine(photon: URL(fileURLWithPath: "/fake/bin/photon"), root: rootPath, port: port)
    }
}

@MainActor
struct AppStateStorePhotonServeTests {
    @Test func autoEnginePicksPhotonWhenDetected() async throws {
        let fixture = try PhotonServeFixture()
        let result = try await fixture.serve().get()
        #expect(fixture.command(result) == fixture.expectedCommand(port: 52200))
        #expect(fixture.session.tree.allPanes.count == 2)
        #expect(result.entry.served?.engine == .photon)
        #expect(fixture.store.serverReply(result).terminalPaneID != nil)
    }

    @Test func autoEnginePicksBuiltinWhenPhotonIsAbsent() async throws {
        let fixture = try PhotonServeFixture()
        fixture.photon = nil
        let result = try await fixture.serve().get()
        #expect(result.entry.backend is InAppStaticServerBackend)
        #expect(fixture.session.tree.allPanes.count == 1)
        #expect(result.entry.served?.engine == .builtin)
    }

    @Test func engineBuiltinUsesTheBuiltinServerWithPhotonPresent() async throws {
        let fixture = try PhotonServeFixture()
        let result = try await fixture.serve(engine: .builtin).get()
        #expect(result.entry.backend is InAppStaticServerBackend)
        #expect(fixture.session.tree.allPanes.count == 1)
        #expect(fixture.searchPaths.isEmpty)
    }

    @Test func enginePhotonWithoutPhotonFailsWithInstallGuidanceAndOpensNoPane() async throws {
        let fixture = try PhotonServeFixture()
        fixture.photon = nil
        let result = await fixture.serve(engine: .photon)
        #expect(serveError(result) == .photonNotInstalled)
        #expect(ServerXPCError.photonNotInstalled.message == PhotonInstall.notInstalledMessage)
        #expect(fixture.session.tree.allPanes.count == 1)
        #expect(fixture.store.servers.entries.isEmpty)
    }

    @Test func explicitPortIsPassedToPhoton() async throws {
        let fixture = try PhotonServeFixture()
        let result = try await fixture.serve(port: 8123).get()
        #expect(fixture.command(result) == fixture.expectedCommand(port: 8123))
        #expect(result.entry.port == 8123)
        #expect(fixture.picks == [52200])
    }

    @Test func pickedPortIsPassedToPhoton() async throws {
        let fixture = try PhotonServeFixture()
        let result = try await fixture.serve().get()
        #expect(fixture.command(result) == fixture.expectedCommand(port: 52200))
        #expect(result.entry.url.absoluteString == "http://127.0.0.1:52200/")
    }

    @Test func pickedPortSkipsPortsTheRegistryHolds() async throws {
        let fixture = try PhotonServeFixture()
        _ = try fixture.base.base.start(port: 52200)
        fixture.picks = [52200, 52201]
        let result = try await fixture.serve().get()
        #expect(result.entry.port == 52201)
    }

    @Test func photonServeOnAPortAnotherEntryHoldsFails() async throws {
        let fixture = try PhotonServeFixture()
        _ = try fixture.base.base.start(port: 8123)
        let result = await fixture.serve(port: 8123)
        #expect(serveError(result) == .portInUse(8123))
    }

    @Test func photonEntryUsesPhotonStopBounds() async throws {
        let fixture = try PhotonServeFixture()
        let result = try await fixture.serve().get()
        #expect(result.entry.stopBounds == .photonServe)
    }

    @Test func photonEntryRegistersOnItsListenerAndLeavesOnExit() async throws {
        let fixture = try PhotonServeFixture()
        let result = try await fixture.serve().get()
        fixture.base.base.scanner.listener = FakeProcessTable.listener
        await result.entry.performTick()
        guard case .listening = result.entry.state else {
            Issue.record("expected listening, got \(result.entry.state)")
            return
        }
        #expect(fixture.base.base.processStatusPanes.count == 1)
        #expect(fixture.store.servers.entries.count == 1)
        let terminal = try #require(fixture.store.serverReply(result).terminalPaneID)
        fixture.session.tree.removePane(id: terminal)
        await result.entry.performTick()
        #expect(fixture.store.servers.entries.isEmpty)
    }

    @Test func photonEntryLeavesTheListWhenPhotonExits() async throws {
        let fixture = try PhotonServeFixture()
        let result = try await fixture.serve().get()
        fixture.base.base.scanner.listener = FakeProcessTable.listener
        await result.entry.performTick()
        #expect(fixture.store.servers.entries.count == 1)
        result.entry.receive(.commandFinished(exitCode: 1))
        #expect(fixture.store.servers.entries.isEmpty)
    }

    @Test func openOnAReusedStartingPhotonEntryWaitsForTheListener() async throws {
        let fixture = try PhotonServeFixture()
        let first = try await fixture.serve().get()
        #expect(first.entry.state == .starting)
        let second = try await fixture.serve(open: true).get()
        #expect(first.entry === second.entry)
        #expect(fixture.base.base.opened.isEmpty)
        fixture.base.base.scanner.listener = FakeProcessTable.listener
        await first.entry.performTick()
        #expect(fixture.base.base.opened == [first.entry.url])
    }

    @Test func openOnAReusedListeningPhotonEntryOpensNow() async throws {
        let fixture = try PhotonServeFixture()
        let first = try await fixture.serve().get()
        fixture.base.base.scanner.listener = FakeProcessTable.listener
        await first.entry.performTick()
        _ = try await fixture.serve(open: true).get()
        #expect(fixture.base.base.opened == [first.entry.url])
    }

    @Test func servingTheSameRootAgainReusesThePhotonEntry() async throws {
        let fixture = try PhotonServeFixture()
        let first = try await fixture.serve().get()
        let second = try await fixture.serve().get()
        #expect(first.entry === second.entry)
        #expect(!second.created)
        #expect(fixture.session.tree.allPanes.count == 2)
    }

    @Test func explicitDifferentEngineOnAServedRootFails() async throws {
        let fixture = try PhotonServeFixture()
        let first = try await fixture.serve().get()
        let result = await fixture.serve(engine: .builtin)
        #expect(serveError(result) == .alreadyServing(root: fixture.rootPath, port: Int(first.entry.port)))
    }

    @Test func openWithPhotonOpensTheBrowserOnFirstListenerOnly() async throws {
        let fixture = try PhotonServeFixture()
        let result = try await fixture.serve(open: true).get()
        #expect(fixture.base.base.opened.isEmpty)
        fixture.base.base.scanner.listener = FakeProcessTable.listener
        await result.entry.performTick()
        #expect(fixture.base.base.opened == [result.entry.url])
        await result.entry.performTick()
        #expect(fixture.base.base.opened == [result.entry.url])
    }

    @Test func serverStartOnAPhotonServePortFails() async throws {
        let fixture = try PhotonServeFixture()
        let served = try await fixture.serve().get()
        #expect(throws: ServerXPCError.alreadyServing(root: fixture.rootPath, port: Int(served.entry.port))) {
            try fixture.base.base.start(port: Int(served.entry.port))
        }
    }

    @Test func listItemAndReplyCarryPhotonKindAndEngine() async throws {
        let fixture = try PhotonServeFixture()
        let result = try await fixture.serve().get()
        let reply = fixture.store.serverReply(result)
        #expect(reply.kind == .photon)
        #expect(reply.engine == .photon)
        #expect(reply.root == fixture.rootPath)
        let item = try #require(fixture.store.listServersForXPC().get().servers.first)
        #expect(item.kind == .photon)
        #expect(item.engine == .photon)
        #expect(ServerEntryDisplay.name(for: result.entry) == URL(fileURLWithPath: fixture.rootPath).lastPathComponent)

        let builtin = try PhotonServeFixture()
        builtin.photon = nil
        let builtinReply = builtin.store.serverReply(try await builtin.serve().get())
        #expect(builtinReply.kind == .static)
        #expect(builtinReply.engine == .builtin)
    }

    @Test func photonDiscoveryReceivesTheCallersSearchPath() async throws {
        let fixture = try PhotonServeFixture()
        _ = try await fixture.serve(searchPath: "/a:/b").get()
        #expect(fixture.searchPaths == ["/a:/b"])
    }

    @Test func openPhotonInstallPaneSplitsAFocusedTerminalPaneInTheCurrentSession() throws {
        let fixture = try PhotonServeFixture()
        let tab = try #require(fixture.store.openPhotonInstallPane(command: PhotonInstall.command))
        #expect(fixture.session.tree.allPanes.count == 2)
        let focused = try #require(fixture.session.tree.allPanes.first { $0.id == fixture.session.tree.focusedPaneID })
        #expect(focused.tabs.map(\.id) == [tab.id])
        #expect(focused.kind == .terminal)
    }
}
