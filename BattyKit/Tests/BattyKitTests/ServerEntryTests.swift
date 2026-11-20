// ServerEntryTests.swift

import Darwin
import Foundation
import Testing
@testable import BattyKit

final class FakePortScanner: PortListenerScanning, @unchecked Sendable {
    var listener: pid_t?
    var scans = 0

    func listeners(port: UInt16) async -> [pid_t] {
        scans += 1
        return listener.map { [$0] } ?? []
    }

    func isListening(pid: pid_t, port: UInt16) async -> Bool {
        scans += 1
        return listener == pid
    }
}

/// A process table for Stop decisions. Pids sit above macOS's highest pid
/// (99998), so the stopper's own checks against Batty's real ancestors never
/// match them.
final class FakeProcessTable: ProcessTableReading, @unchecked Sendable {
    static let batty: pid_t = 100_100
    static let login: pid_t = 100_200
    static let shell: pid_t = 100_600
    static let jobLeader: pid_t = 100_700
    static let listener: pid_t = 100_900

    var selfPid: pid_t = FakeProcessTable.batty
    var records: [pid_t: ProcessRecord] = [:]
    var environments: [pid_t: [String]] = [:]

    /// launchd, Batty's parent, Batty, `login`, the Tab's shell, and a
    /// `go run .` job (leader plus compiled listener) in its own group.
    init(tabID: UUID) {
        add(ProcessRecord(pid: 1, ppid: 0, pgid: 1, uid: 0))
        add(ProcessRecord(pid: 100_050, ppid: 1, pgid: 100_050))
        add(ProcessRecord(pid: Self.batty, ppid: 100_050, pgid: 100_050))
        add(ProcessRecord(pid: Self.login, ppid: Self.batty, pgid: Self.login, uid: 0))
        add(ProcessRecord(pid: Self.shell, ppid: Self.login, pgid: Self.shell))
        environments[Self.shell] = ["HOME=/tmp", ServerJobResolver.tabEnvironmentEntry(tabID)]
        add(ProcessRecord(pid: Self.jobLeader, ppid: Self.shell, pgid: Self.jobLeader, startSeconds: 10))
        add(ProcessRecord(pid: Self.listener, ppid: Self.jobLeader, pgid: Self.jobLeader, startSeconds: 11))
    }

    func add(_ record: ProcessRecord) {
        records[record.pid] = record
    }

    func snapshot() -> ProcessSnapshot { ProcessSnapshot(Array(records.values)) }
    func environment(of pid: pid_t) -> [String]? { environments[pid] }
}

final class FakeHTTPProbe: HTTPProbing, @unchecked Sendable {
    var result: ProbeResult = .noResponse("refused")
    var probes = 0

    func probe(_ url: URL) async -> ProbeResult {
        probes += 1
        return result
    }
}

@MainActor
final class FakeServerTerminalSink: ServerTerminalSink {
    var armed: [String] = []
    var ran: [String] = []
    var observers: [UUID: (Int?) -> Void] = [:]

    func armStartupCommand(_ line: String) { armed.append(line) }
    func runLine(_ line: String) -> Bool { ran.append(line); return true }
    func addCommandFinishedObserver(_ observer: @escaping (Int?) -> Void) -> UUID {
        let id = UUID()
        observers[id] = observer
        return id
    }
    func removeCommandFinishedObserver(_ id: UUID) { observers.removeValue(forKey: id) }
    func finish(_ code: Int?) { for observer in Array(observers.values) { observer(code) } }
}

@MainActor
final class InAppTestBackend: ServerBackend {
    var kind: ServerBackendKind { .inApp }
    var canRestart: Bool { false }
    var canStop: Bool { true }
    var stopsOnTearDown: Bool { true }
    var command: String? { nil }
    var workingDirectory: String? { nil }
    var isAvailable: Bool { true }
    func start(events: @escaping (ServerBackendEvent) -> Void) {}
    func rerun() -> Bool { false }
    func detach() {}
    func stopDecision(listenerPid: pid_t?, table: ProcessTableReading) -> ServerStopDecision {
        guard let listenerPid else { return .nothing }
        return ServerJobResolver.planTreeStop(listener: listenerPid, snapshot: table.snapshot(), selfPid: table.selfPid)
    }
}

@MainActor
struct ServerEntryTests {
    let clock = TestClock()
    let scanner = FakePortScanner()
    let probe = FakeHTTPProbe()
    let signaller = FakeProcessSignaller(diesOn: [SIGINT])
    let sink = FakeServerTerminalSink()
    let tabID: UUID
    let table: FakeProcessTable

    init() {
        let id = UUID()
        tabID = id
        table = FakeProcessTable(tabID: id)
    }

    func terminalBackend(command: String = "go run .", sink: FakeServerTerminalSink? = nil, present: @escaping () -> Bool = { true }, spawnBaseline: ShellSpawnBaseline? = nil) -> TerminalTabServerBackend {
        let target = sink ?? self.sink
        return TerminalTabServerBackend(tabID: tabID, command: command, workingDirectory: "/tmp/site", spawnBaseline: spawnBaseline, lookup: { _ in present() ? target : nil })
    }

    func content(backend: ServerBackend? = nil) -> ServerEntry {
        ServerEntry(
            port: 8083, backend: backend ?? terminalBackend(), clock: clock, scanner: scanner,
            probe: probe, commandLineProvider: { _ in "python3 -m http.server" },
            signaller: signaller, processTable: table, opener: { _ in }
        )
    }

    /// Starts the tick loop and waits until it sleeps; further ticks are
    /// driven with `performTick()`.
    func active(_ content: ServerEntry) async {
        content.setUp(visible: true)
        await clock.waitForSleepers(1)
    }

    @Test func startTypesTheCommandOnceTheShellIsReady() async {
        let content = content()
        content.setUp(visible: false)
        #expect(sink.armed == ["go run ."])
        #expect(sink.ran.isEmpty)
        #expect(content.state == .starting)
    }

    @Test func startingBecomesListeningWhenTheScannerFindsAListener() async {
        let content = content()
        await active(content)
        scanner.listener = FakeProcessTable.listener
        await content.performTick()
        #expect(await content.waitForState { $0 == .listening(pid: FakeProcessTable.listener) } == .listening(pid: FakeProcessTable.listener))
        #expect(content.listenerPid == FakeProcessTable.listener)
    }

    @Test func listeningRecordsHTTPStatusFromTheProbe() async {
        let content = content()
        await active(content)
        scanner.listener = FakeProcessTable.listener
        probe.result = .answered(status: 200)
        await content.performTick()
        #expect(content.httpStatus == 200)
        #expect(content.isResponding == true)
    }

    @Test func listenerOwnedByAnotherUserShowsListeningWithoutPid() async {
        let content = content()
        await active(content)
        probe.result = .answered(status: 301)
        await content.performTick()
        #expect(content.state == .listening(pid: nil))
        #expect(!content.canStop)
    }

    @Test func commandFinishedWithoutStopIsCrashedWithExitCode() {
        let content = content()
        content.setUp(visible: false)
        sink.finish(1)
        #expect(content.state == .crashed(exitCode: 1))
        #expect(content.lastExitCode == 1)
    }

    @Test func exitZeroWithoutStopIsExitedNotCrashed() {
        let content = content()
        content.setUp(visible: false)
        sink.finish(0)
        #expect(content.state == .crashed(exitCode: 0))
        #expect(ServerEntryDisplay.stateText(content.state, isResponding: nil, kind: .terminal) == "Exited (0)")
    }

    @Test func stopSignalsTheJobGroupNotTheShell() async {
        let content = content()
        await active(content)
        scanner.listener = FakeProcessTable.listener
        await content.performTick()
        await content.performStop()
        #expect(signaller.sent.first?.0 == .processGroup(FakeProcessTable.jobLeader))
        #expect(signaller.signals == [SIGINT])
    }

    @Test func stopThenCommandFinishedIsStoppedRequested() async {
        let content = content()
        await active(content)
        scanner.listener = FakeProcessTable.listener
        await content.performTick()
        signaller.diesOn = []
        content.stop()
        _ = await content.waitForState { $0 == .stopping }
        sink.finish(130)
        await clock.waitForSleepers(1)
        await clock.advance(by: .milliseconds(250))
        await content.awaitPendingWork()
        #expect(content.state == .stopped(exitCode: 130, reason: .requested))
        #expect(signaller.signals == [SIGINT])
    }

    @Test func restartStopsThenRetypesTheSameCommandInTheSameTab() async {
        let content = content()
        await active(content)
        scanner.listener = FakeProcessTable.listener
        await content.performTick()
        await content.performRestart()
        #expect(signaller.signals == [SIGINT])
        #expect(sink.ran == ["go run ."])
        #expect(content.state == .starting)
    }

    @Test func terminalTabGoneShowsStoppedTerminalClosed() async {
        var present = true
        let content = content(backend: terminalBackend(present: { present }))
        await active(content)
        present = false
        await content.performTick()
        #expect(content.state == .stopped(exitCode: nil, reason: .terminalClosed))
    }

    @Test func tearDownCancelsTicksAndRemovesTheTabObserverSynchronously() async {
        let content = content()
        await active(content)
        #expect(sink.observers.count == 1)
        content.tearDown()
        #expect(sink.observers.isEmpty)
        #expect(content.lifecyclePhase == .tornDown)
    }

    @Test func tearDownDoesNotStopATerminalBackedServer() async {
        let content = content()
        await active(content)
        scanner.listener = FakeProcessTable.listener
        await content.performTick()
        content.tearDown()
        #expect(signaller.sent.isEmpty)
    }

    @Test func tearDownStopsABackendThatStopsOnTearDown() async {
        let content = content(backend: InAppTestBackend())
        await active(content)
        scanner.listener = FakeProcessTable.listener
        await content.performTick()
        content.tearDown()
        await content.awaitPendingWork()
        #expect(signaller.sent.first?.0 == .processTree(FakeProcessTable.listener))
    }

    @Test func aSharedServerCanNeitherStopNorRestart() async {
        let content = content(backend: ExternalProcessServerBackend())
        content.makeTerminalBackend = { _, _ in nil }
        await active(content)
        scanner.listener = FakeProcessTable.listener
        await content.performTick()
        #expect(content.state == .listening(pid: FakeProcessTable.listener))
        #expect(!content.canStop)
        #expect(!content.canRestart)
        #expect(content.stopRefusal == nil)
    }

    @Test func aSharedServerStopSendsNoSignal() async {
        let content = content(backend: ExternalProcessServerBackend())
        await active(content)
        scanner.listener = FakeProcessTable.listener
        await content.performTick()
        content.stop()
        content.restart()
        await content.awaitPendingWork()
        await content.performRestart()
        #expect(signaller.sent.isEmpty)
        #expect(content.state == .listening(pid: FakeProcessTable.listener))
    }

    /// The review's case: another Tab's agent already serves the port, in a
    /// group under its own shell.
    @Test func stopRefusesAListenerNotDescendedFromTheTabShell() async {
        let content = content()
        table.add(ProcessRecord(pid: 100_250, ppid: FakeProcessTable.batty, pgid: 100_250, uid: 0))
        table.add(ProcessRecord(pid: 100_650, ppid: 100_250, pgid: 100_650))
        table.environments[100_650] = [ServerJobResolver.tabEnvironmentEntry(UUID())]
        table.add(ProcessRecord(pid: 100_750, ppid: 100_650, pgid: 100_750))
        table.add(ProcessRecord(pid: 100_950, ppid: 100_750, pgid: 100_750))
        await active(content)
        scanner.listener = 100_950
        await content.performTick()
        #expect(content.state == .listening(pid: 100_950))
        #expect(content.listenerPid == 100_950)
        #expect(content.stopRefusal != nil)
        #expect(!content.canStop)
        #expect(!content.canRestart)
        #expect(await content.performStop() == false)
        await content.performRestart()
        #expect(signaller.sent.isEmpty)
        #expect(sink.ran.isEmpty)
        #expect(content.state == .listening(pid: 100_950))
    }

    @Test func stopRefusesAListenerFromAnotherApp() async {
        let content = content()
        table.add(ProcessRecord(pid: 100_960, ppid: 1, pgid: 100_960))
        await active(content)
        scanner.listener = 100_960
        await content.performTick()
        #expect(content.stopRefusal != nil)
        #expect(await content.performStop() == false)
        #expect(signaller.sent.isEmpty)
    }

    @Test func stopRefusesAListenerInTheShellsOwnGroup() async {
        let content = content()
        table.add(ProcessRecord(pid: 100_970, ppid: FakeProcessTable.shell, pgid: FakeProcessTable.shell))
        await active(content)
        scanner.listener = 100_970
        await content.performTick()
        #expect(content.stopRefusal != nil)
        #expect(await content.performStop() == false)
        #expect(signaller.sent.isEmpty)
    }

    @Test func stopRefusesAJobGroupHoldingAProcessOutsideTheTab() async {
        let content = content()
        table.add(ProcessRecord(pid: 100_980, ppid: 1, pgid: FakeProcessTable.jobLeader))
        await active(content)
        scanner.listener = FakeProcessTable.listener
        await content.performTick()
        #expect(content.stopRefusal != nil)
        #expect(signaller.sent.isEmpty)
    }

    @Test func stopRefusesWhenTheTabShellIsNotFound() async {
        let content = content()
        table.environments[FakeProcessTable.shell] = ["HOME=/tmp"]
        await active(content)
        scanner.listener = FakeProcessTable.listener
        await content.performTick()
        #expect(content.stopRefusal != nil)
        #expect(await content.performStop() == false)
        #expect(signaller.sent.isEmpty)
    }

    @Test func pidReusedDuringEscalationIsNotSignalled() async {
        let content = content()
        await active(content)
        scanner.listener = FakeProcessTable.listener
        await content.performTick()
        signaller.diesOn = []
        let stop = Task { await content.performStop() }
        // The tick loop's sleeper plus the stopper's first wait after SIGINT.
        await clock.waitForSleepers(2)
        let reused = ProcessRecord(pid: FakeProcessTable.jobLeader, ppid: FakeProcessTable.shell, pgid: FakeProcessTable.jobLeader, startSeconds: 99)
        table.add(reused)
        // The refusal itself may be cleared by a tick that runs while the
        // clock is driven, since the reused pid is a new job of the same Tab.
        #expect(await drive(stop, clock: clock) == false)
        #expect(signaller.signals == [SIGINT])
        #expect(content.state == .listening(pid: FakeProcessTable.listener))
    }

    /// The Tab's shell hides its environment, so it is found by start time
    /// after a baseline; a tick with a listener caches it.
    func cachedHiddenShellContent() async -> ServerEntry {
        table.environments[FakeProcessTable.shell] = []
        table.add(ProcessRecord(pid: FakeProcessTable.login, ppid: FakeProcessTable.batty, pgid: FakeProcessTable.login, uid: 0, startSeconds: 50))
        let content = content(backend: terminalBackend(spawnBaseline: ShellSpawnBaseline(seconds: 40, microseconds: 0)))
        scanner.listener = FakeProcessTable.listener
        await active(content)
        await content.performTick()
        #expect(content.stopRefusal == nil)
        return content
    }

    /// A newer Tab whose hidden-environment shell started after the baseline
    /// and whose job group listens on the Pane's port.
    func addNewerTabServingThePort() {
        table.add(ProcessRecord(pid: 100_210, ppid: FakeProcessTable.batty, pgid: 100_210, uid: 0, startSeconds: 60))
        table.add(ProcessRecord(pid: 100_610, ppid: 100_210, pgid: 100_610, startSeconds: 60))
        table.environments[100_610] = []
        table.add(ProcessRecord(pid: 100_710, ppid: 100_610, pgid: 100_710, startSeconds: 61))
        table.add(ProcessRecord(pid: 100_910, ppid: 100_710, pgid: 100_710, startSeconds: 62))
        scanner.listener = 100_910
    }

    @Test func stopRefusesAfterTheTabShellExitsEvenWhenANewerShellHoldsThePort() async {
        let content = await cachedHiddenShellContent()
        for pid in [FakeProcessTable.shell, FakeProcessTable.jobLeader, FakeProcessTable.listener] {
            table.records.removeValue(forKey: pid)
        }
        addNewerTabServingThePort()
        await content.performTick()
        #expect(content.stopRefusal?.contains("exited") == true)
        #expect(await content.performStop() == false)
        await content.performRestart()
        #expect(sink.ran.isEmpty)
        #expect(signaller.sent.isEmpty)
    }

    @Test func zombieTabShellRefusesStopWithoutRelookup() async {
        let content = await cachedHiddenShellContent()
        table.add(ProcessRecord(pid: FakeProcessTable.shell, ppid: FakeProcessTable.login, pgid: FakeProcessTable.shell, isZombie: true))
        addNewerTabServingThePort()
        await content.performTick()
        #expect(content.stopRefusal?.contains("exited") == true)
        #expect(await content.performStop() == false)
        #expect(signaller.sent.isEmpty)
    }

    @Test func stopRetriesTheLookupWhileNoShellHasBeenFound() async {
        table.environments[FakeProcessTable.shell] = []
        table.add(ProcessRecord(pid: FakeProcessTable.login, ppid: FakeProcessTable.batty, pgid: FakeProcessTable.login, uid: 0, startSeconds: 50))
        table.add(ProcessRecord(pid: 100_210, ppid: FakeProcessTable.batty, pgid: 100_210, uid: 0, startSeconds: 51))
        table.add(ProcessRecord(pid: 100_610, ppid: 100_210, pgid: 100_610, startSeconds: 51))
        let content = content(backend: terminalBackend(spawnBaseline: ShellSpawnBaseline(seconds: 40, microseconds: 0)))
        scanner.listener = FakeProcessTable.listener
        await active(content)
        await content.performTick()
        #expect(content.stopRefusal?.contains("not found") == true)
        table.records.removeValue(forKey: 100_210)
        table.records.removeValue(forKey: 100_610)
        await content.performTick()
        #expect(content.stopRefusal == nil)
        _ = await content.performStop()
        #expect(signaller.sent.first?.0 == .processGroup(FakeProcessTable.jobLeader))
    }

    @Test func listenerChangeFiresOnListenerChangeOncePerPid() async {
        let content = content(backend: ExternalProcessServerBackend())
        var seen: [pid_t] = []
        content.onListenerChange = { _, pid in seen.append(pid) }
        await active(content)
        await content.performTick()
        #expect(seen.isEmpty)
        scanner.listener = FakeProcessTable.listener
        await content.performTick()
        await content.performTick()
        #expect(seen == [FakeProcessTable.listener])
        scanner.listener = 100_950
        await content.performTick()
        #expect(seen == [FakeProcessTable.listener, 100_950])
    }

    @Test func tailnetMenuActionCoversShareStopAndAdopted() {
        #expect(ServerEntryDisplay.tailnetMenuAction(hasURL: false, adopted: false, offersSharing: true) == .share)
        #expect(ServerEntryDisplay.tailnetMenuAction(hasURL: false, adopted: false, offersSharing: false) == nil)
        #expect(ServerEntryDisplay.tailnetMenuAction(hasURL: true, adopted: false, offersSharing: true) == .stop)
        #expect(ServerEntryDisplay.tailnetMenuAction(hasURL: true, adopted: true, offersSharing: false) == .adoptedNote)
    }
}
