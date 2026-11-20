// ServerRegistryTests.swift

import Foundation
import Testing
@testable import BattyKit

@MainActor
struct ServerRegistryTests {
    let clock = TestClock()
    let scanner = FakePortScanner()
    let probe = FakeHTTPProbe()
    let sink = FakeServerTerminalSink()
    let registry = ServerRegistry()

    func entry(port: UInt16 = 8083, backend: ServerBackend) -> ServerEntry {
        ServerEntry(
            port: port, backend: backend, clock: clock, scanner: scanner, probe: probe,
            commandLineProvider: { _ in nil }, signaller: FakeProcessSignaller(),
            processTable: FakeProcessTable(tabID: UUID()), opener: { _ in }
        )
    }

    func terminalEntry(port: UInt16 = 8083, present: @escaping () -> Bool = { true }) -> ServerEntry {
        let sink = sink
        return entry(port: port, backend: TerminalTabServerBackend(tabID: UUID(), command: "go run .", workingDirectory: "/tmp", spawnBaseline: nil, lookup: { _ in present() ? sink : nil }))
    }

    func external(port: UInt16) -> ServerEntry {
        entry(port: port, backend: ExternalProcessServerBackend())
    }

    @Test func registerAddsEntriesInOrder() {
        let a = external(port: 8001), b = external(port: 8002)
        registry.register(a)
        registry.register(b)
        #expect(registry.entries.map(\.id) == [a.id, b.id])
        registry.remove(id: a.id)
        registry.remove(id: b.id)
    }

    @Test func entryForPortIsAppWide() {
        let a = external(port: 8001)
        registry.register(a)
        #expect(registry.entry(port: 8001) === a)
        #expect(registry.entry(id: a.id) === a)
        #expect(registry.entry(port: 8002) == nil)
        registry.remove(id: a.id)
    }

    @Test func registerTwiceIsANoOp() {
        let a = external(port: 8001)
        registry.register(a)
        registry.register(a)
        #expect(registry.entries.count == 1)
        registry.remove(id: UUID())
        #expect(registry.entries.count == 1)
        registry.remove(id: a.id)
    }

    @Test func crashedEntryLeavesTheRegistry() {
        let entry = terminalEntry()
        registry.register(entry)
        sink.finish(2)
        #expect(entry.state == .crashed(exitCode: 2))
        #expect(registry.entries.isEmpty)
        #expect(entry.lifecyclePhase == .tornDown)
    }

    @Test func stoppedEntryLeavesTheRegistry() async {
        let entry = entry(backend: FakeInProcessBackend())
        registry.register(entry)
        entry.stop()
        await entry.awaitPendingWork()
        #expect(entry.state == .stopped(exitCode: nil, reason: .requested))
        #expect(registry.entries.isEmpty)
    }

    @Test func terminalClosedEntryLeavesTheRegistry() async {
        var present = true
        let entry = terminalEntry(present: { present })
        registry.register(entry)
        present = false
        await entry.performTick()
        #expect(entry.state == .stopped(exitCode: nil, reason: .terminalClosed))
        #expect(registry.entries.isEmpty)
    }

    @Test func restartKeepsTheEntryThroughItsStoppedStep() async {
        let entry = entry(backend: FakeInProcessBackend())
        registry.register(entry)
        await entry.performTick()
        entry.restart()
        await entry.awaitPendingWork()
        #expect(entry.state == .starting)
        #expect(registry.entries.map(\.id) == [entry.id])
        registry.remove(id: entry.id)
    }

    @Test func removeTearsTheEntryDown() async {
        let entry = terminalEntry()
        registry.register(entry)
        #expect(await clock.waitForSleepers(1))
        let scans = scanner.scans
        registry.remove(id: entry.id)
        #expect(entry.lifecyclePhase == .tornDown)
        await clock.advance(by: .seconds(10))
        #expect(scanner.scans == scans)
        #expect(registry.entries.isEmpty)
    }

    @Test func activeEntriesExcludeFinished() {
        let running = external(port: 8001)
        registry.register(running)
        let crashed = terminalEntry(port: 8002)
        registry.register(crashed)
        #expect(registry.activeEntries.count == 2)
        sink.finish(1)
        #expect(registry.activeEntries.map(\.id) == [running.id])
        registry.remove(id: running.id)
    }
}

@MainActor
struct ServerEntryDisplayTests {
    let scanner = FakePortScanner()
    let clock = TestClock()

    func entry(port: UInt16 = 8083, backend: ServerBackend, commandLine: String? = nil) -> ServerEntry {
        ServerEntry(
            port: port, backend: backend, clock: clock, scanner: scanner, probe: FakeHTTPProbe(),
            commandLineProvider: { _ in commandLine }, signaller: FakeProcessSignaller(),
            processTable: FakeProcessTable(tabID: UUID()), opener: { _ in }
        )
    }

    @Test func nameIsTheCommandsProgram() {
        let python = entry(backend: TerminalTabServerBackend(tabID: UUID(), command: "python3 -m http.server 8000", workingDirectory: "/tmp", lookup: { _ in nil }))
        #expect(ServerEntryDisplay.name(for: python) == "python3")
        let npm = entry(backend: TerminalTabServerBackend(tabID: UUID(), command: "/usr/local/bin/npm run dev", workingDirectory: "/tmp", lookup: { _ in nil }))
        #expect(ServerEntryDisplay.name(for: npm) == "npm")
    }

    @Test func nameIsTheServedFoldersName() {
        let backend = InAppStaticServerBackend(resolver: StaticFilePathResolver(root: FileManager.default.temporaryDirectory)!, injectsReloadScript: false)
        let expected = URL(fileURLWithPath: backend.root).lastPathComponent
        #expect(ServerEntryDisplay.name(for: entry(backend: backend)) == expected)
    }

    @Test func nameOfASharedServerComesFromItsCommandLine() async {
        let attached = entry(backend: ExternalProcessServerBackend(), commandLine: "/opt/homebrew/bin/node server.js")
        scanner.listener = 4321
        attached.setUp(visible: true)
        #expect(await clock.waitForSleepers(1))
        #expect(ServerEntryDisplay.name(for: attached) == "node")
        attached.tearDown()
    }

    @Test func nameIsTheCustomNameWhenGiven() {
        let shared = entry(backend: TerminalTabServerBackend(tabID: UUID(), command: "node server.js", workingDirectory: "/tmp", lookup: { _ in nil }))
        #expect(ServerEntryDisplay.name(for: shared) == "node")
        shared.customName = "site"
        #expect(ServerEntryDisplay.name(for: shared) == "site")
    }

    @Test func nameFallsBackToThePort() {
        let attached = entry(port: 9123, backend: ExternalProcessServerBackend())
        #expect(ServerEntryDisplay.name(for: attached) == "Port 9123")
    }

    @Test func addressIsLoopbackAndPort() {
        #expect(ServerEntryDisplay.address(port: 8000) == "127.0.0.1:8000")
    }

    @Test func defaultURLIsLoopback127() {
        #expect(entry(port: 8000, backend: ExternalProcessServerBackend()).url.absoluteString == "http://127.0.0.1:8000/")
    }
}

struct ServersToolbarVisibilityTests {
    @Test func hiddenWithNoServersAndSettingOff() {
        #expect(!ServersToolbarVisibility.isVisible(flagOn: true, activeCount: 0, alwaysShow: false))
    }

    @Test func shownWithOneActiveServer() {
        #expect(ServersToolbarVisibility.isVisible(flagOn: true, activeCount: 1, alwaysShow: false))
    }

    @Test func shownWithSettingOnAndNoServers() {
        #expect(ServersToolbarVisibility.isVisible(flagOn: true, activeCount: 0, alwaysShow: true))
    }

    @Test func hiddenWithFlagOffEvenWithServersOrSetting() {
        #expect(!ServersToolbarVisibility.isVisible(flagOn: false, activeCount: 2, alwaysShow: true))
    }

    @Test func alwaysShowDefaultsOff() {
        let defaults = UserDefaults(suiteName: "ServersToolbarVisibilityTests-\(UUID().uuidString)")!
        #expect(defaults.object(forKey: SettingsPreference.alwaysShowServersKey) == nil)
        #expect(SettingsPreference.defaultAlwaysShowServers == false)
    }
}
