// ServerBackend.swift

import Foundation

public nonisolated enum ServerBackendEvent: Equatable, Sendable {
    case commandFinished(exitCode: Int?)
    case terminalGone
}

public nonisolated enum ServerBackendKind: Equatable, Sendable {
    /// The command runs in a Batty terminal Tab.
    case terminal
    /// A process Batty didn't start.
    case external
    /// A server Batty runs itself, with no terminal (#0649).
    case inApp
}

/// How a tracked server runs, separate from how it is watched, so a
/// new way of running a server needs no change to the view or the monitor.
@MainActor
public protocol ServerBackend: AnyObject {
    var kind: ServerBackendKind { get }
    var canRestart: Bool { get }
    var canStop: Bool { get }
    /// True only for a backend with no terminal to own the process: closing
    /// the entry then stops the server.
    var stopsOnTearDown: Bool { get }
    var command: String? { get }
    var workingDirectory: String? { get }
    /// False once the terminal that ran the command is gone.
    var isAvailable: Bool { get }
    /// Begins delivering events and, for a terminal backend, types the
    /// command once the shell is ready.
    func start(events: @escaping (ServerBackendEvent) -> Void)
    /// Types the command again in the same terminal. False when it can't.
    func rerun() -> Bool
    /// Stops delivering events.
    func detach()
    /// What Stop may signal, given the listener found on the port, or why it
    /// must not signal anything.
    func stopDecision(listenerPid: pid_t?, table: ProcessTableReading) -> ServerStopDecision
}

/// What the Servers list knows about a server that runs inside Batty.
public nonisolated struct ServingFacts: Equatable, Sendable {
    public var root: String
    public var requestCount: Int
    public var reloadClientCount: Int
    public var lastChangeAt: Date?
    public var injectsReloadScript: Bool

    public init(root: String, requestCount: Int, reloadClientCount: Int, lastChangeAt: Date?, injectsReloadScript: Bool) {
        self.root = root
        self.requestCount = requestCount
        self.reloadClientCount = reloadClientCount
        self.lastChangeAt = lastChangeAt
        self.injectsReloadScript = injectsReloadScript
    }
}

/// A server whose listener is Batty itself (#0649). The entry never
/// scans, probes, samples or signals for it: every one of those would find
/// Batty's own pid.
@MainActor
public protocol InProcessServerBackend: ServerBackend {
    var isServing: Bool { get }
    var servingFacts: ServingFacts { get }
    func stopServing()
    /// Serves again on the same port; awaits the stopped listener's
    /// release of it first.
    func resumeServing() async throws(StaticServerError)
}

/// A terminal Tab, as a server's terminal backend needs it, so tests
/// never need a live surface.
@MainActor
public protocol ServerTerminalSink: AnyObject {
    /// Types `line` once the shell reports it is ready.
    func armStartupCommand(_ line: String)
    @discardableResult func runLine(_ line: String) -> Bool
    func addCommandFinishedObserver(_ observer: @escaping (Int?) -> Void) -> UUID
    func removeCommandFinishedObserver(_ id: UUID)
}

@MainActor
public final class TabRuntimeServerTerminalSink: ServerTerminalSink {
    private weak var tab: TabRuntime?

    public init(tab: TabRuntime) {
        self.tab = tab
    }

    public func armStartupCommand(_ line: String) {
        tab?.armStartupCommand(line)
    }

    public func runLine(_ line: String) -> Bool {
        tab?.runCommandLine(line) ?? false
    }

    public func addCommandFinishedObserver(_ observer: @escaping (Int?) -> Void) -> UUID {
        tab?.addCommandFinishedObserver(observer) ?? UUID()
    }

    public func removeCommandFinishedObserver(_ id: UUID) {
        tab?.removeCommandFinishedObserver(id)
    }
}

@MainActor
public final class TerminalTabServerBackend: ServerBackend {
    public let tabID: UUID
    public private(set) var command: String?
    public private(set) var workingDirectory: String?
    private let lookup: (UUID) -> ServerTerminalSink?
    private var observerID: UUID?
    private var observedSink: ServerTerminalSink?
    private var events: ((ServerBackendEvent) -> Void)?

    /// Taken before the Tab was created, to find its shell by start time.
    private let spawnBaseline: ShellSpawnBaseline?

    public init(tabID: UUID, command: String, workingDirectory: String?, spawnBaseline: ShellSpawnBaseline? = nil, lookup: @escaping (UUID) -> ServerTerminalSink?) {
        self.tabID = tabID
        self.spawnBaseline = spawnBaseline
        self.command = command
        self.workingDirectory = workingDirectory
        self.lookup = lookup
    }

    public var kind: ServerBackendKind { .terminal }
    public var canRestart: Bool { true }
    public var canStop: Bool { true }
    public var stopsOnTearDown: Bool { false }
    public var isAvailable: Bool { lookup(tabID) != nil }

    public func update(command: String, workingDirectory: String?) {
        self.command = command
        self.workingDirectory = workingDirectory
    }

    public func start(events: @escaping (ServerBackendEvent) -> Void) {
        self.events = events
        guard let sink = attach() else {
            events(.terminalGone)
            return
        }
        if let command { sink.armStartupCommand(command) }
    }

    public func rerun() -> Bool {
        guard let command, let sink = attach() else { return false }
        return sink.runLine(command)
    }

    public func detach() {
        if let observerID { observedSink?.removeCommandFinishedObserver(observerID) }
        observerID = nil
        observedSink = nil
        events = nil
    }

    private func attach() -> ServerTerminalSink? {
        guard let sink = lookup(tabID) else { return nil }
        if observerID == nil || observedSink !== sink {
            if let observerID { observedSink?.removeCommandFinishedObserver(observerID) }
            observerID = sink.addCommandFinishedObserver { [weak self] code in
                self?.events?(.commandFinished(exitCode: code))
            }
            observedSink = sink
        }
        return sink
    }

    /// The Tab's shell, found once and never replaced: a later lookup could
    /// pick a newer Tab's shell that also started after the baseline.
    private var shellStamp: ProcessStamp?

    /// The listener's job group, only when the listener descends from this
    /// Tab's own shell and its group is not the shell's.
    public func stopDecision(listenerPid: pid_t?, table: ProcessTableReading) -> ServerStopDecision {
        guard let listenerPid else { return .nothing }
        let snapshot = table.snapshot()
        let shell: ProcessRecord
        if let shellStamp {
            guard let record = snapshot.records[shellStamp.pid], record.stamp == shellStamp, !record.isZombie else {
                return .refused("the shell of this server's terminal has exited")
            }
            shell = record
        } else {
            guard let found = ServerJobResolver.locateTabShell(tabID: tabID, spawnedAfter: spawnBaseline, snapshot: snapshot, table: table) else {
                return .refused("the shell of this server's terminal was not found")
            }
            shellStamp = found.stamp
            shell = found
        }
        return ServerJobResolver.planGroupStop(listener: listenerPid, shell: shell, snapshot: snapshot, selfPid: table.selfPid)
    }
}

/// A shared server (`batty server share`): a process Batty didn't start.
/// Batty watches it and never signals it.
@MainActor
public final class ExternalProcessServerBackend: ServerBackend {
    public init() {}

    public var kind: ServerBackendKind { .external }
    public var command: String? { nil }
    public var workingDirectory: String? { nil }
    public var canRestart: Bool { false }
    public var canStop: Bool { false }
    public var stopsOnTearDown: Bool { false }
    public var isAvailable: Bool { true }

    public func start(events: @escaping (ServerBackendEvent) -> Void) {}
    public func rerun() -> Bool { false }
    public func detach() {}

    public func stopDecision(listenerPid: pid_t?, table: ProcessTableReading) -> ServerStopDecision {
        .nothing
    }
}
