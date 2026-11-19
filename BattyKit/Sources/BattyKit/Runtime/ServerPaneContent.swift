// ServerPaneContent.swift

import AppKit
import Foundation
import Observation
import OSLog

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "ServerPaneContent")

public nonisolated enum ServerStopReason: Equatable, Sendable {
    case requested
    case terminalClosed
}

public nonisolated enum ServerPaneState: Equatable, Sendable {
    /// The command was typed, or attach is waiting, and nothing listens yet.
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

public nonisolated struct ServerProcessSample: Equatable, Sendable {
    public var cpuTicks: UInt64
    public var footprintBytes: UInt64
    public var startDate: Date?

    public init(cpuTicks: UInt64, footprintBytes: UInt64, startDate: Date?) {
        self.cpuTicks = cpuTicks
        self.footprintBytes = footprintBytes
        self.startDate = startDate
    }
}

public nonisolated struct ServerProcessMetrics: Equatable, Sendable {
    public var cpuPercent: Double?
    public var footprintBytes: UInt64
    public var startDate: Date?
}

/// A Server Pane: watches one port (listener scan, HTTP probe, metrics,
/// stats) and drives Stop and Restart through its `ServerBackend`.
@MainActor
@Observable
public final class ServerPaneContent: PaneContentLifecycle {
    public static let tickInterval: Duration = .seconds(1)
    static let probeEveryTicks = 5
    static let statsEveryTicks = 2

    public let port: UInt16
    public let url: URL
    public let explicitStatsURL: URL?
    public private(set) var backend: ServerBackend
    public private(set) var state: ServerPaneState
    public private(set) var listenerPid: pid_t?
    public private(set) var metrics: ServerProcessMetrics?
    public private(set) var lastExitCode: Int?
    public private(set) var httpStatus: Int?
    public private(set) var isResponding: Bool?
    public private(set) var stats = ServerStatsHistory()
    public private(set) var statsVisible = false
    public private(set) var statsUnavailableReason: String?
    public private(set) var recoveredCommandLine: String?
    /// Why Stop and Restart won't signal the listener, when it isn't
    /// provably this Pane's server (for example a process from another Tab
    /// that holds the port).
    public private(set) var stopRefusal: String?
    /// The in-app server's facts, copied on each tick while visible.
    public private(set) var servingFacts: ServingFacts?
    /// Why the last in-app Restart failed.
    public private(set) var lastError: String?

    private let controller = PaneLifecycleController()
    public var lifecyclePhase: PaneLifecyclePhase { controller.phase }

    @ObservationIgnored private let clock: SchedulingClock
    @ObservationIgnored private let scanner: PortListenerScanning
    @ObservationIgnored private let probe: HTTPProbing
    @ObservationIgnored private let statsFetcher: ServerStatsFetching
    @ObservationIgnored private let metricsProvider: @MainActor (pid_t) -> ServerProcessSample?
    @ObservationIgnored private let commandLineProvider: @MainActor (pid_t) -> String?
    @ObservationIgnored private let signaller: ProcessSignalling
    @ObservationIgnored private let processTable: ProcessTableReading
    @ObservationIgnored private let stopBounds: StopBounds
    @ObservationIgnored private let opener: @MainActor (URL) -> Void
    /// Opens a Web Preview Pane for `url`; set by the store.
    @ObservationIgnored public var openPreview: (() -> Void)?
    /// Makes a terminal backend in a new terminal Pane under this one, for
    /// Restart when there is no terminal to type into. Set by the store.
    @ObservationIgnored public var makeTerminalBackend: ((_ command: String, _ workingDirectory: String?) -> ServerBackend?)?

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
    @ObservationIgnored private var statsSuspended = false
    @ObservationIgnored private var previousSample: (ticks: UInt64, at: Date, pid: pid_t)?
    @ObservationIgnored private var stateWaiters: [UUID: (predicate: (ServerPaneState) -> Bool, continuation: CheckedContinuation<ServerPaneState, Never>)] = [:]

    public init(
        port: UInt16,
        url: URL? = nil,
        statsURL: URL? = nil,
        backend: ServerBackend,
        clock: SchedulingClock = SystemClock(),
        scanner: PortListenerScanning = SystemPortListenerScanner(),
        probe: HTTPProbing? = nil,
        statsFetcher: ServerStatsFetching? = nil,
        metricsProvider: @escaping @MainActor (pid_t) -> ServerProcessSample? = ServerPaneContent.liveSample,
        commandLineProvider: @escaping @MainActor (pid_t) -> String? = { try? ProcessInspector.commandLine(pid: $0).get() },
        signaller: ProcessSignalling = SystemProcessSignaller(),
        processTable: ProcessTableReading = SystemProcessTable(),
        stopBounds: StopBounds = StopBounds(),
        opener: @escaping @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) },
        startsBackendOnSetUp: Bool = true
    ) {
        self.startsBackendOnSetUp = startsBackendOnSetUp
        self.port = port
        self.url = url ?? URL(string: "http://localhost:\(port)/")!
        self.explicitStatsURL = statsURL
        self.backend = backend
        self.state = .starting
        self.clock = clock
        self.scanner = scanner
        let shared = (probe == nil || statsFetcher == nil) ? URLSessionHTTPProbe() : nil
        self.probe = probe ?? shared!
        self.statsFetcher = statsFetcher ?? shared!
        self.metricsProvider = metricsProvider
        self.commandLineProvider = commandLineProvider
        self.signaller = signaller
        self.processTable = processTable
        self.stopBounds = stopBounds
        self.opener = opener
    }

    public static func liveSample(pid: pid_t) -> ServerProcessSample? {
        guard case .success(let core) = ProcessInspector.coreMetrics(pid: pid) else { return nil }
        let start = ProcessInspector.listedIdentity(pid: pid).map {
            Date(timeIntervalSince1970: TimeInterval($0.startSeconds) + TimeInterval($0.startMicroseconds) / 1_000_000)
        }
        return ServerProcessSample(cpuTicks: core.cpuTicksUser &+ core.cpuTicksSystem, footprintBytes: core.physFootprintBytes, startDate: start)
    }

    // MARK: - Stats URL

    /// `--stats-url`, else `/debug/vars` on the server's origin.
    public var statsURL: URL? {
        if let explicitStatsURL { return explicitStatsURL }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.path = "/debug/vars"
        components?.query = nil
        components?.fragment = nil
        return components?.url
    }

    /// The stats host when it isn't loopback, for the section header.
    public var nonLoopbackStatsHost: String? {
        guard let host = statsURL?.host, !URLSessionHTTPProbe.isLoopback(host: host) else { return nil }
        return host
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

    public func setVisible(_ visible: Bool) {
        switch controller.apply(visible ? .show : .hide) {
        case .applied(_, .active): startTicks()
        case .applied(_, .suspended): stopTicks()
        default: break
        }
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
                previousSample = nil
                if backend.kind == .external { recoveredCommandLine = commandLineProvider(found) }
                refreshStopRefusal()
            } else if stopRefusal != nil {
                refreshStopRefusal()
            }
            if state != .listening(pid: found) {
                setState(.listening(pid: found))
                statsSuspended = false
                statsUnavailableReason = nil
            }
            sampleMetrics(pid: found)
        } else if wasListening {
            listenerPid = nil
            metrics = nil
            stopRefusal = nil
            if case .listening = state { setState(.starting) }
        }

        let justBecameListening = !wasListening && found != nil
        if justBecameListening || state == .starting || tick % Self.probeEveryTicks == 1 {
            await runProbe(generationAtStart)
        }
        guard isCurrent(generationAtStart) else { return }
        if case .listening = state, !statsSuspended, justBecameListening || tick % Self.statsEveryTicks == 0 {
            await fetchStats(generationAtStart)
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
                statsSuspended = false
            }
        case .noResponse:
            if isResponding == true { isResponding = false }
        }
    }

    private func fetchStats(_ generationAtStart: Int) async {
        guard let statsURL else { return }
        let isExpvar = explicitStatsURL == nil
        let result = await statsFetcher.fetch(statsURL)
        guard isCurrent(generationAtStart) else { return }
        let failure: String?
        switch result {
        case .body(let status, let data):
            if (200..<300).contains(status), let snapshot = ServerStatsParser.parse(data, isExpvar: isExpvar) {
                stats.append(snapshot)
                statsVisible = true
                statsUnavailableReason = nil
                return
            }
            failure = (200..<300).contains(status) ? "not a JSON object" : "HTTP \(status)"
        case .failed(let reason):
            failure = reason
        }
        if isExpvar {
            statsSuspended = true
            statsVisible = false
        } else {
            statsUnavailableReason = failure
        }
    }

    private func sampleMetrics(pid: pid_t) {
        guard let sample = metricsProvider(pid) else {
            metrics = nil
            return
        }
        let now = clock.now
        var cpu: Double?
        if let previous = previousSample, previous.pid == pid, sample.cpuTicks >= previous.ticks {
            let seconds = now.timeIntervalSince(previous.at)
            if seconds > 0 {
                let busy = Double(sample.cpuTicks - previous.ticks) * MachTimebase.nanosecondsPerTick / 1_000_000_000
                cpu = busy / seconds * 100
            }
        }
        previousSample = (sample.cpuTicks, now, pid)
        metrics = ServerProcessMetrics(cpuPercent: cpu, footprintBytes: sample.footprintBytes, startDate: sample.startDate)
    }

    // MARK: - Events

    func receive(_ event: ServerBackendEvent) {
        switch event {
        case .commandFinished(let code):
            lastExitCode = code
            listenerPid = nil
            metrics = nil
            stopRefusal = nil
            if stopRequested {
                finishedDuringStop = true
                setState(.stopped(exitCode: code, reason: .requested))
            } else if state.isRunning {
                setState(.crashed(exitCode: code))
            }
        case .terminalGone:
            listenerPid = nil
            metrics = nil
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
            self?.stopTask = nil
        }
    }

    public func restart() {
        guard canRestart, stopTask == nil else { return }
        stopTask = Task { [weak self] in
            await self?.performRestart()
            self?.stopTask = nil
        }
    }

    public func openInBrowser() {
        opener(url)
    }

    public var canOpenPreview: Bool {
        guard case .listening = state, openPreview != nil else { return false }
        return WebPreviewURLPolicy.isAllowedTopLevel(url)
    }

    /// Stops an attached server, if running, then swaps in `replacement`:
    /// `server start` on a port whose Pane was attach-mode.
    public func convert(to replacement: ServerBackend) {
        let previous = stopTask
        stopTask = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            if self.backend.kind == .external, self.state.isRunning, self.canStop {
                guard await self.performStop() else {
                    self.stopTask = nil
                    return
                }
            }
            self.replaceBackend(replacement)
            self.stopTask = nil
        }
    }

    /// The in-flight Stop, Restart or conversion, for tests and the XPC
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
        metrics = nil
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
    /// whose Pane was attach-mode or lost its terminal.
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
        metrics = nil
        httpStatus = nil
        isResponding = nil
        statsSuspended = false
        statsVisible = false
        stats = ServerStatsHistory()
        setState(.starting)
    }

    // MARK: - State waiters

    private func setState(_ new: ServerPaneState) {
        guard state != new else { return }
        state = new
        for (id, waiter) in stateWaiters where waiter.predicate(new) {
            stateWaiters.removeValue(forKey: id)
            waiter.continuation.resume(returning: new)
        }
    }

    private func resolveAllWaiters() {
        let waiters = stateWaiters
        stateWaiters.removeAll()
        for waiter in waiters.values { waiter.continuation.resume(returning: state) }
    }

    /// Resolves with the first state matching `predicate`, now or on a later
    /// write; also resolves (with the current state) on teardown or when the
    /// awaiting task is cancelled.
    public func waitForState(_ predicate: @escaping (ServerPaneState) -> Bool) async -> ServerPaneState {
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
