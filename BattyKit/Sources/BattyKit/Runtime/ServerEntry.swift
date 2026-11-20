// ServerEntry.swift

import AppKit
import Foundation
import Observation
import OSLog

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "ServerEntry")

public nonisolated enum ServerStopReason: Equatable, Sendable {
    case requested
    case terminalClosed
}

public nonisolated enum ServerEntryState: Equatable, Sendable {
    /// The command was typed, or a shared server is waiting, and nothing listens yet.
    case starting
    /// `pid` is nil when the listener belongs to another user.
    case listening(pid: pid_t?)
    case stopping
    case stopped(exitCode: Int?, reason: ServerStopReason)
    /// Exited without a Stop. Exit 0 displays as "Exited (0)".
    case crashed(exitCode: Int?)

    public var isRunning: Bool {
        switch self {
        case .starting, .listening, .stopping: true
        case .stopped, .crashed: false
        }
    }
}

/// One tracked server in the app-wide `ServerRegistry`: watches one port
/// (listener scan, HTTP probe) and drives Stop and Restart through its
/// `ServerBackend`.
@MainActor
@Observable
public final class ServerEntry {
    public static let tickInterval: Duration = .seconds(1)
    static let probeEveryTicks = 5

    public let id = UUID()
    public let port: UInt16
    public let url: URL
    /// The `https://<host>.<tailnet>.ts.net[:port]/` URL while the port is
    /// served on the tailnet (`TailnetSharing`); nil otherwise.
    public internal(set) var tailnetURL: URL?
    /// The tailnet URL is served by a mapping Batty found and didn't make,
    /// so Batty never turns it off.
    public internal(set) var isTailnetAdopted = false
    /// Why the last tailnet share or stop failed, in the tool's words.
    public internal(set) var tailnetError: String?
    /// True while a tailnet share or stop runs for this entry.
    public internal(set) var isTailnetBusy = false
    public private(set) var backend: ServerBackend
    public private(set) var state: ServerEntryState
    public private(set) var listenerPid: pid_t?
    public private(set) var lastExitCode: Int?
    public private(set) var httpStatus: Int?
    public private(set) var isResponding: Bool?
    public private(set) var recoveredCommandLine: String?
    /// Why Stop and Restart won't signal the listener, when it isn't
    /// provably this entry's server (for example a process from another Tab
    /// that holds the port).
    public private(set) var stopRefusal: String?
    /// The in-app server's facts, copied on each tick.
    public private(set) var servingFacts: ServingFacts?
    /// Why the last in-app Restart failed.
    public private(set) var lastError: String?

    private let controller = PaneLifecycleController()
    public var lifecyclePhase: PaneLifecyclePhase { controller.phase }

    @ObservationIgnored private let clock: SchedulingClock
    @ObservationIgnored private let scanner: PortListenerScanning
    @ObservationIgnored private let probe: HTTPProbing
    @ObservationIgnored private let commandLineProvider: @MainActor (pid_t) -> String?
    @ObservationIgnored private let signaller: ProcessSignalling
    @ObservationIgnored private let processTable: ProcessTableReading
    @ObservationIgnored private let stopBounds: StopBounds
    @ObservationIgnored private let opener: @MainActor (URL) -> Void
    /// Makes a terminal backend in a new terminal Pane, for Restart when
    /// there is no terminal to type into. Set by the store.
    @ObservationIgnored public var makeTerminalBackend: ((_ command: String, _ workingDirectory: String?) -> ServerBackend?)?

    /// The Servers list row's name, from `--name`.
    public var customName: String?
    /// The Process Status Pane watching this server's listener.
    @ObservationIgnored public var processStatusPaneID: UUID?
    /// True until the first listener opens the Process Status Pane
    /// (`server start` without `--no-process-view`).
    @ObservationIgnored public var wantsProcessStatus = false
    /// Called from a tick when the listener changes to a found pid.
    @ObservationIgnored public var onListenerChange: ((ServerEntry, pid_t) -> Void)?

    /// The Pane `server start` was called from; Restart splits a new
    /// terminal Pane from it once the old terminal is gone.
    @ObservationIgnored public var anchorPaneID: UUID?
    /// Called once the entry is no longer running and no Stop or Restart is
    /// in flight. The registry removes the entry.
    @ObservationIgnored var onFinished: (@MainActor (ServerEntry) -> Void)?

    /// False when the creator builds the backend's terminal after this
    /// content is set up, and calls `startBackend()` itself.
    @ObservationIgnored private let startsBackendOnSetUp: Bool
    @ObservationIgnored private var backendStarted = false
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var stopTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var tickCount = 0
    @ObservationIgnored private var stopRequested = false
    @ObservationIgnored private var finishedDuringStop = false
    @ObservationIgnored private var stateWaiters: [UUID: (predicate: (ServerEntryState) -> Bool, continuation: CheckedContinuation<ServerEntryState, Never>)] = [:]

    public init(
        port: UInt16,
        url: URL? = nil,
        backend: ServerBackend,
        clock: SchedulingClock = SystemClock(),
        scanner: PortListenerScanning = SystemPortListenerScanner(),
        probe: HTTPProbing? = nil,
        commandLineProvider: @escaping @MainActor (pid_t) -> String? = { try? ProcessInspector.commandLine(pid: $0).get() },
        signaller: ProcessSignalling = SystemProcessSignaller(),
        processTable: ProcessTableReading = SystemProcessTable(),
        stopBounds: StopBounds = StopBounds(),
        opener: @escaping @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) },
        startsBackendOnSetUp: Bool = true
    ) {
        self.startsBackendOnSetUp = startsBackendOnSetUp
        self.port = port
        self.url = url ?? URL(string: "http://127.0.0.1:\(port)/")!
        self.backend = backend
        self.state = .starting
        self.clock = clock
        self.scanner = scanner
        self.probe = probe ?? URLSessionHTTPProbe()
        self.commandLineProvider = commandLineProvider
        self.signaller = signaller
        self.processTable = processTable
        self.stopBounds = stopBounds
        self.opener = opener
    }

    // MARK: - Lifecycle

    public func setUp(visible: Bool) {
        let result = controller.apply(.setUp(visible: visible))
        guard case .applied(_, let to) = result else { return }
        if startsBackendOnSetUp { startBackend() }
        if to == .active { startTicks() }
    }

    public func startBackend() {
        guard !backendStarted, controller.phase != .tornDown else { return }
        backendStarted = true
        backend.start(events: { [weak self] in self?.receive($0) })
    }

    public func tearDown() {
        guard case .applied = controller.apply(.tearDown) else { return }
        stopTicks()
        stopTask?.cancel()
        stopTask = nil
        (backend as? InProcessServerBackend)?.stopServing()
        let shouldStop = backend.stopsOnTearDown && !(backend is InProcessServerBackend)
        let decision = shouldStop ? backend.stopDecision(listenerPid: listenerPid, table: processTable) : .nothing
        backend.detach()
        if case .signal(let plan) = decision {
            let signaller = signaller
            let clock = clock
            let bounds = stopBounds
            let check = Self.recheck(plan, table: processTable)
            stopTask = Task { _ = await ProcessGroupStopper.stop(plan.target, signaller: signaller, clock: clock, bounds: bounds, check: check) }
        } else if case .refused(let reason) = decision {
            logger.error("teardown stop on port \(self.port, privacy: .public) refused: \(reason, privacy: .public)")
        }
        resolveAllWaiters()
    }

    private func startTicks() {
        generation += 1
        task?.cancel()
        let clock = clock
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.performTick()
                await clock.sleep(for: Self.tickInterval)
            }
        }
    }

    private func stopTicks() {
        generation += 1
        task?.cancel()
        task = nil
    }

    // MARK: - Ticks

    func performTick() async {
        guard controller.phase == .active else { return }
        let generationAtStart = generation
        tickCount += 1
        let tick = tickCount

        if backend.kind == .terminal, !backend.isAvailable, state != .stopped(exitCode: nil, reason: .terminalClosed) {
            receive(.terminalGone)
            return
        }
        if let inProcess = backend as? InProcessServerBackend {
            let facts = inProcess.servingFacts
            if servingFacts != facts { servingFacts = facts }
            if inProcess.isServing, state == .starting { setState(.listening(pid: nil)) }
            return
        }
        guard state.isRunning, state != .stopping else { return }

        let wasListening = listenerPid != nil
        var found: pid_t?
        if let pid = listenerPid, await scanner.isListening(pid: pid, port: port) {
            found = pid
        } else {
            found = await scanner.listeners(port: port).first
        }
        guard isCurrent(generationAtStart), state.isRunning, state != .stopping else { return }

        if let found {
            if listenerPid != found {
                listenerPid = found
                if backend.kind == .external { recoveredCommandLine = commandLineProvider(found) }
                refreshStopRefusal()
                onListenerChange?(self, found)
            } else if stopRefusal != nil {
                refreshStopRefusal()
            }
            if state != .listening(pid: found) {
                setState(.listening(pid: found))
            }
        } else if wasListening {
            listenerPid = nil
            stopRefusal = nil
            if case .listening = state { setState(.starting) }
        }

        let justBecameListening = !wasListening && found != nil
        if justBecameListening || state == .starting || tick % Self.probeEveryTicks == 1 {
            await runProbe(generationAtStart)
        }
    }

    private func refreshStopRefusal() {
        let refusal: String?
        if case .refused(let reason) = backend.stopDecision(listenerPid: listenerPid, table: processTable) {
            refusal = reason
        } else {
            refusal = nil
        }
        if refusal != stopRefusal {
            if let refusal { logger.info("port \(self.port, privacy: .public): Stop unavailable: \(refusal, privacy: .public)") }
            stopRefusal = refusal
        }
    }

    /// Re-reads the process table before each signal.
    private static func recheck(_ plan: StopPlan, table: ProcessTableReading) -> () -> StopCheck {
        { ServerJobResolver.check(plan, snapshot: table.snapshot(), selfPid: table.selfPid) }
    }

    private func isCurrent(_ generationAtStart: Int) -> Bool {
        controller.phase == .active && generation == generationAtStart
    }

    private func runProbe(_ generationAtStart: Int) async {
        let result = await probe.probe(url)
        guard isCurrent(generationAtStart) else { return }
        switch result {
        case .answered(let status):
            httpStatus = status
            isResponding = true
            if state == .starting, listenerPid == nil {
                setState(.listening(pid: nil))
            }
        case .noResponse:
            if isResponding == true { isResponding = false }
        }
    }

    // MARK: - Events

    func receive(_ event: ServerBackendEvent) {
        switch event {
        case .commandFinished(let code):
            lastExitCode = code
            listenerPid = nil
            stopRefusal = nil
            if stopRequested {
                finishedDuringStop = true
                setState(.stopped(exitCode: code, reason: .requested))
            } else if state.isRunning {
                setState(.crashed(exitCode: code))
            }
        case .terminalGone:
            listenerPid = nil
            stopRefusal = nil
            setState(.stopped(exitCode: nil, reason: .terminalClosed))
        }
    }

    // MARK: - Actions (event origin)

    public var canStop: Bool {
        guard backend.canStop, stopRefusal == nil, state.isRunning, state != .stopping else { return false }
        if case .listening(nil) = state, !(backend is InProcessServerBackend) { return false }
        return true
    }

    public var canRestart: Bool {
        guard stopRefusal == nil else { return false }
        return backend.canRestart || (backend.command != nil && makeTerminalBackend != nil)
    }

    public func stop() {
        guard canStop, stopTask == nil else { return }
        stopTask = Task { [weak self] in
            await self?.performStop()
            self?.finishPendingWork()
        }
    }

    public func restart() {
        guard canRestart, stopTask == nil else { return }
        stopTask = Task { [weak self] in
            await self?.performRestart()
            self?.finishPendingWork()
        }
    }

    public func openInBrowser() {
        opener(url)
    }

    private func finishPendingWork() {
        stopTask = nil
        notifyIfFinished()
    }

    private func notifyIfFinished() {
        guard !state.isRunning, stopTask == nil, controller.phase != .tornDown else { return }
        onFinished?(self)
    }

    /// The in-flight Stop or Restart, for tests and the XPC
    /// replies.
    public func awaitPendingWork() async {
        await stopTask?.value
    }

    /// False when Stop refused to signal; `stopRefusal` then says why.
    @discardableResult
    func performStop() async -> Bool {
        guard canStop else { return stopRefusal == nil }
        if let inProcess = backend as? InProcessServerBackend {
            inProcess.stopServing()
            stopRequested = true
            setState(.stopped(exitCode: nil, reason: .requested))
            return true
        }
        let decision = backend.stopDecision(listenerPid: listenerPid, table: processTable)
        let plan: StopPlan
        switch decision {
        case .nothing:
            logger.info("stop: nothing to signal on port \(self.port, privacy: .public)")
            stopRequested = true
            setState(.stopped(exitCode: lastExitCode, reason: .requested))
            return true
        case .refused(let reason):
            logger.error("stop on port \(self.port, privacy: .public) refused: \(reason, privacy: .public)")
            stopRefusal = reason
            return false
        case .signal(let value):
            plan = value
        }
        stopRequested = true
        finishedDuringStop = false
        let resumeState = state
        setState(.stopping)
        let outcome = await ProcessGroupStopper.stop(
            plan.target, signaller: signaller, clock: clock, bounds: stopBounds,
            exitEvent: { [weak self] in self?.finishedDuringStop ?? true },
            check: Self.recheck(plan, table: processTable)
        )
        logger.info("stop on port \(self.port, privacy: .public): \(String(describing: outcome), privacy: .public)")
        if case .refused(let reason) = outcome, !finishedDuringStop {
            stopRequested = false
            stopRefusal = reason
            if state == .stopping { setState(resumeState) }
            return false
        }
        listenerPid = nil
        if state == .stopping {
            setState(.stopped(exitCode: lastExitCode, reason: .requested))
        }
        return true
    }

    func performRestart() async {
        guard stopRefusal == nil else { return }
        if let inProcess = backend as? InProcessServerBackend {
            if inProcess.isServing { inProcess.stopServing() }
            do {
                try await inProcess.resumeServing()
            } catch {
                if lastError != error.message { lastError = error.message }
                setState(.stopped(exitCode: nil, reason: .requested))
                return
            }
            guard controller.phase != .tornDown else {
                inProcess.stopServing()
                return
            }
            if lastError != nil { lastError = nil }
            beginStarting()
            return
        }
        if state.isRunning, canStop {
            guard await performStop() else { return }
        }
        if backend.isAvailable, backend.canRestart, backend.kind == .terminal {
            guard backend.rerun() else { return }
        } else if let command = backend.command, let factory = makeTerminalBackend, let replacement = factory(command, backend.workingDirectory) {
            replaceBackend(replacement)
        } else {
            return
        }
        beginStarting()
    }

    /// Swaps in a new backend and starts it, as `server start` on a port
    /// a shared entry holds while nothing listens, or whose terminal is gone.
    public func replaceBackend(_ replacement: ServerBackend) {
        backend.detach()
        backend = replacement
        if backendStarted {
            replacement.start(events: { [weak self] in self?.receive($0) })
        }
        beginStarting()
    }

    /// Replaces the stored command of a terminal backend; the next Restart
    /// types the new one.
    public func update(command: String, workingDirectory: String?) {
        (backend as? TerminalTabServerBackend)?.update(command: command, workingDirectory: workingDirectory)
    }

    private func beginStarting() {
        stopRequested = false
        stopRefusal = nil
        finishedDuringStop = false
        listenerPid = nil
        httpStatus = nil
        isResponding = nil
        setState(.starting)
    }

    // MARK: - State waiters

    private func setState(_ new: ServerEntryState) {
        guard state != new else { return }
        state = new
        for (id, waiter) in stateWaiters where waiter.predicate(new) {
            stateWaiters.removeValue(forKey: id)
            waiter.continuation.resume(returning: new)
        }
        notifyIfFinished()
    }

    private func resolveAllWaiters() {
        let waiters = stateWaiters
        stateWaiters.removeAll()
        for waiter in waiters.values { waiter.continuation.resume(returning: state) }
    }

    /// Resolves with the first state matching `predicate`, now or on a later
    /// write; also resolves (with the current state) on teardown or when the
    /// awaiting task is cancelled.
    public func waitForState(_ predicate: @escaping (ServerEntryState) -> Bool) async -> ServerEntryState {
        if predicate(state) || controller.phase == .tornDown { return state }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: state)
                } else {
                    stateWaiters[id] = (predicate, continuation)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, let waiter = self.stateWaiters.removeValue(forKey: id) else { return }
                waiter.continuation.resume(returning: self.state)
            }
        }
    }
}
