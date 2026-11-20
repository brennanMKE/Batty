// TailnetSharingTests.swift

import BattyXPCCore
import Foundation
import Testing
@testable import BattyKit

@MainActor
private final class TailnetFixture {
    let base = ServerStoreFixture()
    var date = Date(timeIntervalSince1970: 1_000_000)

    init() {
        base.store.tailnet.now = { [unowned self] in self.date }
    }

    var store: AppStateStore { base.store }
    var tailnet: TailnetSharing { base.store.tailnet }
    var fake: FakeTailscaleRunner { base.tailscale }

    /// A shared (external) server on `port`, with detection settled.
    func entry(port: Int = 3000) async throws -> ServerEntry {
        base.scanner.listener = FakeProcessTable.listener
        let entry = try await base.share(port: port, processView: false).entry
        await tailnet.refreshStatusIfStale()?.value
        return entry
    }

    /// The calls made by `operation`.
    func calls(during operation: () async throws -> Void) async rethrows -> [[String]] {
        let before = fake.calls.count
        try await operation()
        return Array(fake.calls.dropFirst(before))
    }

    func settle(_ port: UInt16) async {
        await tailnet.pending[port]?.value
    }
}

@MainActor
struct TailnetSharingTests {
    let on3000 = TailscaleArgs.serveOn(port: 3000)
    let off3000 = TailscaleArgs.serveOff(port: 3000)

    @Test func noTailscaleCallsWhileNoServersAreTracked() async {
        let fixture = TailnetFixture()
        #expect(fixture.tailnet.refreshStatusIfStale() == nil)
        #expect(fixture.fake.calls.isEmpty)
    }

    @Test func detectionRunsOnlyStatusJSON() async throws {
        let fixture = TailnetFixture()
        _ = try await fixture.entry()
        #expect(fixture.fake.calls == [["status", "--json"]])
        #expect(fixture.tailnet.status == .running(dnsName: "host.tailnet.ts.net", httpsEnabled: true))
        #expect(fixture.tailnet.offersSharing)
    }

    @Test func statusIsCachedBriefly() async throws {
        let fixture = TailnetFixture()
        _ = try await fixture.entry()
        #expect(fixture.tailnet.refreshStatusIfStale() == nil)
        #expect(fixture.fake.calls.count == 1)
        fixture.date += 11
        await fixture.tailnet.refreshStatusIfStale()?.value
        #expect(fixture.fake.calls.count == 2)
    }

    @Test func absentCLIMeansNoTailnetOffer() async throws {
        let fixture = TailnetFixture()
        fixture.tailnet.locate = { nil }
        _ = try await fixture.entry()
        #expect(!fixture.tailnet.offersSharing)
        #expect(fixture.fake.calls.isEmpty)
    }

    @Test func stoppedTailscaleMeansNoTailnetOffer() async throws {
        let fixture = TailnetFixture()
        fixture.fake.status = TailscaleFixtures.stopped
        _ = try await fixture.entry()
        #expect(!fixture.tailnet.offersSharing)
    }

    @Test func nothingRunsServeWithoutAShareRequest() async throws {
        let fixture = TailnetFixture()
        let shared = try await fixture.entry()
        let started = try fixture.base.start(port: 8083)
        fixture.store.servers.remove(id: started.entry.id)
        fixture.store.unshareServer(shared)
        await fixture.settle(3000)
        #expect(fixture.fake.calls.allSatisfy { $0 == TailscaleArgs.status })
    }

    @Test func shareRunsServeBgHTTPSWithTheLocalPort() async throws {
        let fixture = TailnetFixture()
        let entry = try await fixture.entry()
        var result: Result<URL, TailnetError>?
        let calls = await fixture.calls { result = await fixture.tailnet.share(entry: entry).value }
        #expect(calls == [["status", "--json"], ["serve", "status", "--json"], ["serve", "--bg", "--https=3000", "http://127.0.0.1:3000"], ["serve", "status", "--json"]])
        #expect(try result?.get().absoluteString == "https://host.tailnet.ts.net:3000/")
        #expect(entry.tailnetURL?.absoluteString == "https://host.tailnet.ts.net:3000/")
        #expect(entry.tailnetError == nil)
        #expect(!entry.isTailnetBusy)
        #expect(fixture.tailnet.ownedPorts == [3000])
    }

    @Test func shareOnPort443HasNoPortInTheURL() async throws {
        let fixture = TailnetFixture()
        let entry = try await fixture.entry(port: 443)
        _ = await fixture.tailnet.share(entry: entry).value
        #expect(entry.tailnetURL?.absoluteString == "https://host.tailnet.ts.net/")
    }

    private func expectShareFails(status: String, message: String) async throws {
        let fixture = TailnetFixture()
        fixture.fake.status = status
        let entry = try await fixture.entry()
        let result = await fixture.tailnet.share(entry: entry).value
        #expect(throws: TailnetError.self) { try result.get() }
        #expect(entry.tailnetError == message)
        #expect(entry.tailnetURL == nil)
        #expect(fixture.fake.serveCalls.isEmpty)
    }

    @Test func shareFailsWhenLoggedOut() async throws {
        try await expectShareFails(status: TailscaleFixtures.loggedOut, message: "Tailscale is logged out; log in, then try again")
    }

    @Test func shareFailsWhenStopped() async throws {
        try await expectShareFails(status: TailscaleFixtures.stopped, message: "Tailscale isn't running (state: Stopped)")
    }

    @Test func shareFailsWhenHTTPSIsOff() async throws {
        try await expectShareFails(status: TailscaleFixtures.runningNoHTTPS, message: TailnetError.httpsDisabled.message)
    }

    @Test func shareFailsWithoutAMagicDNSName() async throws {
        try await expectShareFails(status: TailscaleFixtures.missingSelf, message: TailnetError.noDNSName.message)
    }

    @Test func shareSurfacesTheToolsMessage() async throws {
        let fixture = TailnetFixture()
        let entry = try await fixture.entry()
        fixture.fake.nextServeResult = TailscaleCommandResult(exitCode: 1, stderr: "serve: access denied\n")
        _ = await fixture.tailnet.share(entry: entry).value
        #expect(entry.tailnetError == "tailscale serve failed: serve: access denied")
        #expect(entry.tailnetURL == nil)
        #expect(fixture.tailnet.ownedPorts.isEmpty)
    }

    @Test func shareReportsATimeout() async throws {
        let fixture = TailnetFixture()
        let entry = try await fixture.entry()
        fixture.fake.nextServeResult = TailscaleCommandResult(exitCode: 15, stdout: "To enable HTTPS, visit", timedOut: true)
        let result = await fixture.tailnet.share(entry: entry).value
        #expect(throws: TailnetError.timedOut("To enable HTTPS, visit")) { try result.get() }
        #expect(fixture.tailnet.ownedPorts.isEmpty)
    }

    @Test func shareFailsWhenServeStatusDoesNotShowTheMapping() async throws {
        let fixture = TailnetFixture()
        fixture.fake.appliesServe = false
        let entry = try await fixture.entry()
        let result = await fixture.tailnet.share(entry: entry).value
        #expect(throws: TailnetError.notApplied) { try result.get() }
        #expect(fixture.tailnet.ownedPorts.isEmpty)
    }

    @Test func turningOffRunsTheSameCommandWithOff() async throws {
        let fixture = TailnetFixture()
        let entry = try await fixture.entry()
        _ = await fixture.tailnet.share(entry: entry).value
        _ = await fixture.tailnet.unshare(port: 3000, entry: entry).value
        #expect(fixture.fake.calls.last == ["serve", "--bg", "--https=3000", "http://127.0.0.1:3000", "off"])
        #expect(entry.tailnetURL == nil)
        #expect(fixture.tailnet.ownedPorts.isEmpty)
    }

    @Test func stoppingASharedServerTurnsOffItsMapping() async throws {
        let fixture = TailnetFixture()
        let entry = try await fixture.entry()
        _ = await fixture.tailnet.share(entry: entry).value
        fixture.store.servers.remove(id: entry.id)
        await fixture.settle(3000)
        #expect(fixture.fake.calls.last == off3000)
        #expect(fixture.fake.mappings.isEmpty)
    }

    @Test func unshareOfASharedExternalServerTurnsOffItsMapping() async throws {
        let fixture = TailnetFixture()
        let entry = try await fixture.entry()
        _ = await fixture.tailnet.share(entry: entry).value
        _ = try fixture.store.unshareServerForXPC(ServerControlRequest(port: 3000)).get()
        await fixture.settle(3000)
        #expect(fixture.fake.calls.last == off3000)
    }

    @Test func aMappingBattyDidNotAddIsNeverRemoved() async throws {
        let fixture = TailnetFixture()
        fixture.fake.serveOverride = TailscaleFixtures.foreignOn3000
        let entry = try await fixture.entry()
        let shared = await fixture.tailnet.share(entry: entry).value
        #expect(throws: TailnetError.portTaken(3000)) { try shared.get() }
        let off = await fixture.tailnet.unshare(port: 3000, entry: entry, reportForeign: true).value
        #expect(throws: TailnetError.notOurs(3000)) { try off.get() }
        fixture.store.servers.remove(id: entry.id)
        await fixture.settle(3000)
        #expect(fixture.fake.serveCalls.isEmpty)
    }

    @Test func anIdenticalPreexistingMappingIsAdoptedButNeverTurnedOff() async throws {
        let fixture = TailnetFixture()
        fixture.fake.serveOverride = TailscaleFixtures.oursOn3000
        let entry = try await fixture.entry()
        _ = await fixture.tailnet.share(entry: entry).value
        #expect(entry.tailnetURL?.absoluteString == "https://host.tailnet.ts.net:3000/")
        #expect(fixture.tailnet.ownedPorts.isEmpty)
        _ = await fixture.tailnet.unshare(port: 3000, entry: entry).value
        #expect(entry.tailnetURL == nil)
        fixture.store.servers.remove(id: entry.id)
        await fixture.settle(3000)
        #expect(fixture.fake.serveCalls.isEmpty)
    }

    @Test func aMappingChangedAfterSharingIsLeftInPlace() async throws {
        let fixture = TailnetFixture()
        let entry = try await fixture.entry()
        _ = await fixture.tailnet.share(entry: entry).value
        fixture.fake.serveOverride = TailscaleFixtures.foreignOn3000
        _ = await fixture.tailnet.unshare(port: 3000, entry: entry).value
        #expect(!fixture.fake.calls.contains(off3000))
        #expect(fixture.tailnet.ownedPorts.isEmpty)
    }

    @Test func twoHandlersOnThePortAreNotTurnedOff() async throws {
        let fixture = TailnetFixture()
        let entry = try await fixture.entry()
        _ = await fixture.tailnet.share(entry: entry).value
        fixture.fake.serveOverride = TailscaleFixtures.twoHandlersOn3000
        _ = await fixture.tailnet.unshare(port: 3000, entry: entry).value
        #expect(!fixture.fake.calls.contains(off3000))
    }

    @Test func operationsOnOnePortRunInOrder() async throws {
        let fixture = TailnetFixture()
        let entry = try await fixture.entry()
        let share = fixture.tailnet.share(entry: entry)
        fixture.store.servers.remove(id: entry.id)
        _ = await share.value
        await fixture.settle(3000)
        let calls = fixture.fake.calls
        let on = try #require(calls.firstIndex(of: on3000))
        let off = try #require(calls.firstIndex(of: off3000))
        #expect(on < off)
    }

    @Test func quitRemovesOnlyOwnedMappings() async throws {
        let fixture = TailnetFixture()
        fixture.fake.mappings = [4000: "http://127.0.0.1:4000"]
        let owned = try await fixture.entry(port: 3000)
        let adopted = try await fixture.entry(port: 4000)
        _ = await fixture.tailnet.share(entry: owned).value
        _ = await fixture.tailnet.share(entry: adopted).value
        #expect(fixture.tailnet.ownedPorts == [3000])
        await fixture.tailnet.removeOwnedMappingsForQuit()
        #expect(fixture.fake.serveCalls == [on3000, off3000])
        #expect(fixture.fake.mappings == [4000: "http://127.0.0.1:4000"])
    }

    @Test func aFailedOffKeepsThePortOwnedForQuit() async throws {
        let fixture = TailnetFixture()
        let entry = try await fixture.entry()
        _ = await fixture.tailnet.share(entry: entry).value
        fixture.fake.nextServeResult = TailscaleCommandResult(exitCode: 1, stderr: "busy")
        _ = await fixture.tailnet.unshare(port: 3000, entry: entry).value
        #expect(entry.tailnetError == "tailscale serve failed: busy")
        #expect(fixture.tailnet.ownedPorts == [3000])
        await fixture.tailnet.removeOwnedMappingsForQuit()
        #expect(fixture.tailnet.ownedPorts.isEmpty)
        #expect(fixture.fake.mappings.isEmpty)
    }
}
