// LMStudioDashboardPaneContent.swift

import Foundation
import Observation
import OSLog

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "LMStudioDashboardPaneContent")

/// Model-owned conformer to `PaneContentLifecycle` for the
/// `lm-studio-dashboard` pane kind (`docs/design/lmstudio-dashboard-view.md`).
/// Hung off `PaneRuntime` the same way `TabRuntime.terminal` is
/// (`docs/pane-view-lifecycle.md` §5) — never owned by a view's `@State`,
/// so SwiftUI rebuild churn never re-runs `setUp`/tears down the poller and
/// subprocesses out from under it.
///
/// Data sources (design doc §5): two concurrent `lms log stream`
/// subprocesses (`-s model --stats` for predictions, `-s runtime` for
/// engine diagnostics — never `-s server`, which design doc §1.8 found
/// leaks full request/completion bodies at the default log level), plus
/// HTTP polling of `/api/v1/models` (1 s) and `lms ps --json` (3 s,
/// secondary enrichment only — busy/idle's primary signal is the log
/// stream's own in-flight count, since `lms ps` measured ~14x more
/// expensive live, design doc §1.7).
///
/// Every dependency that touches the outside world is an injectable
/// closure with a production default, mirroring `FootprintMonitor`'s
/// `limitBytesProvider`/`footprintBytesProvider` pattern — this is what
/// lets `LMStudioDashboardPaneContentTests` drive the not-installed,
/// unreachable, and reconnect-backoff states deterministically without a
/// real LM Studio server.
@MainActor
@Observable
public final class LMStudioDashboardPaneContent: PaneContentLifecycle {
    // MARK: - Injectable dependencies

    public var cliExecutableURLProvider: () -> URL? = { LMStudioCLI.resolveExecutableURL() }
    public var fetchModels: () async throws -> LMStudioModelsResponse = {
        try await LMStudioHTTPClient.fetchModels()
    }
    public var fetchPsEntries: (URL) async throws -> [LMStudioPsEntry] = { url in
        try await LMStudioCLI.runPsAsync(executableURL: url)
    }
    public var makeModelStreamProcess: (URL) -> Process = { url in
        LMStudioCLI.makeLogStreamProcess(executableURL: url, source: "model", includeStats: true)
    }
    public var makeRuntimeStreamProcess: (URL) -> Process = { url in
        LMStudioCLI.makeLogStreamProcess(executableURL: url, source: "runtime", includeStats: false)
    }

    // MARK: - Tunables

    public var modelsPollInterval: Duration = .seconds(1)
    public var psPollInterval: Duration = .seconds(3)
    /// The `/api/v1/models` poll backs off to this cadence once the server
    /// is declared unreachable, rather than stopping — design doc §5.
    public var reachabilityPollInterval: Duration = .seconds(5)
    /// How long an unmatched `input` event is kept as "in-flight" before
    /// being evicted as stale (design doc §6) — long enough that no real
    /// prediction should still be running, short enough to recover from a
    /// dropped/reconnected log-stream subprocess losing an `output` event.
    public var staleInFlightWindow: TimeInterval = 5 * 60
    /// Delay before respawning a log-stream subprocess that exited
    /// unexpectedly while the pane is active and the server is reachable.
    public var respawnDelay: Duration = .seconds(2)
    /// Bound on how long `tearDown()`/hide-with-bounded-wait polls
    /// `Process.isRunning` after `SIGTERM`, per design doc §7's
    /// "a few hundred milliseconds" — matching `#0289`'s lesson that a log
    /// line is not evidence of release, generalized to subprocess exit.
    public var teardownWaitBound: TimeInterval = 0.5

    public static let completionCap = BellFeedStore.cap
    public static let inspectorCap = 5
    public static let engineErrorCap = 50

    // MARK: - Observable state

    public private(set) var loadedModels: [LMStudioLoadedModelSummary] = []
    public private(set) var catalogCount: Int = 0
    public private(set) var psByIdentifier: [String: LMStudioPsEntry] = [:]
    /// Newest-first.
    public private(set) var inFlight: [LMStudioInFlightRequest] = []
    /// Newest-first, capped at `completionCap` (`BellFeedStore.cap`).
    public private(set) var recentCompletions: [LMStudioCompletionRecord] = []
    /// Newest-first, capped at `engineErrorCap`.
    public private(set) var engineErrors: [LMStudioEngineLogEntry] = []
    /// Newest-first, capped at `inspectorCap`. Always empty unless
    /// `promptInspectorEnabled` is (or very recently was) `true`.
    public private(set) var inspectorEntries: [LMStudioInspectorRecord] = []
    public private(set) var lastModelsPollAt: Date?

    /// Design doc §2.1 Option A: off by default. Toggling off clears
    /// `inspectorEntries` immediately (§6's "release everything now, not
    /// eventually" discipline applied to a user-initiated privacy action).
    public var promptInspectorEnabled: Bool = false {
        didSet {
            guard promptInspectorEnabled != oldValue, !promptInspectorEnabled else { return }
            inspectorEntries.removeAll()
            pendingPrompts.removeAll()
        }
    }

    public var connectionState: LMStudioConnectionState {
        if !cliAvailable { return .notInstalled }
        if !hasCompletedFirstModelsPoll { return .checking }
        if !httpReachable { return .unreachable }
        if isReconnectingStream { return .reconnecting }
        return .connected
    }

    // MARK: - Lifecycle

    private let controller = PaneLifecycleController()
    public var lifecyclePhase: PaneLifecyclePhase { controller.phase }

    // MARK: - Private runtime state

    private var cliAvailable = false
    private var httpReachable = true
    private var hasCompletedFirstModelsPoll = false
    private var consecutiveModelsPollFailures = 0
    private var isReconnectingStream = false

    private var modelStreamProcess: Process?
    private var runtimeStreamProcess: Process?
    private var modelStreamBuffer = Data()
    private var runtimeStreamBuffer = Data()
    private var expectingModelStreamExit = false
    private var expectingRuntimeStreamExit = false

    private var modelsPollTask: Task<Void, Never>?
    private var psPollTask: Task<Void, Never>?

    private var contextLengthByModelIdentifier: [String: Int] = [:]
    /// Raw prompt text for an in-flight request, keyed by that request's
    /// `LMStudioInFlightRequest.id` — only populated while
    /// `promptInspectorEnabled`. Never read except to pair with the
    /// matching completion and move into `inspectorEntries`.
    private var pendingPrompts: [UUID: String] = [:]

    public init() {}

    // MARK: - PaneContentLifecycle

    public func setUp(visible: Bool) {
        let result = controller.apply(.setUp(visible: visible))
        guard case .applied = result else { return }
        cliAvailable = cliExecutableURLProvider() != nil
        logger.info("setUp visible=\(visible, privacy: .public) cliAvailable=\(self.cliAvailable, privacy: .public)")
        Task { [weak self] in await self?.pollModelsOnce() }
        if visible {
            startActiveWork()
        }
    }

    public func setVisible(_ visible: Bool) {
        let event: PaneLifecycleEvent = visible ? .show : .hide
        let result = controller.apply(event)
        guard case .applied(_, let to) = result else { return }
        switch to {
        case .active:
            logger.info("setVisible(true): resuming")
            startActiveWork()
            Task { [weak self] in await self?.pollModelsOnce() }
        case .suspended:
            logger.info("setVisible(false): suspending")
            stopActiveWork(discardHistory: true, boundedWait: false)
        default:
            break
        }
    }

    public func tearDown() {
        let result = controller.apply(.tearDown)
        guard case .applied = result else { return }
        logger.info("tearDown")
        stopActiveWork(discardHistory: true, boundedWait: true)
    }

    /// Manual refresh (design doc §5's header "Retry"/refresh affordance):
    /// an out-of-cycle `/api/v1/models` probe, not a re-invocation of
    /// `setUp` (which the lifecycle state machine would reject as illegal
    /// after the first call).
    public func refreshNow() {
        Task { [weak self] in await self?.pollModelsOnce() }
    }

    // MARK: - Starting/stopping periodic work

    private func startActiveWork() {
        cliAvailable = cliExecutableURLProvider() != nil
        if let cliURL = cliExecutableURLProvider() {
            spawnModelStream(executableURL: cliURL)
            spawnRuntimeStream(executableURL: cliURL)
            startPsPollTask()
        } else {
            logger.notice("startActiveWork: lms CLI not found; live prediction feed and engine errors unavailable")
        }
        startModelsPollTask()
    }

    private func stopActiveWork(discardHistory: Bool, boundedWait: Bool) {
        modelsPollTask?.cancel()
        modelsPollTask = nil
        stopPsPollTask()
        // `terminateModelStream`/`terminateRuntimeStream` set their own
        // `expecting…StreamExit` flag internally, only when there's an
        // actual process to terminate (review round 1, S2) — not set here.
        terminateModelStream(boundedWait: boundedWait)
        terminateRuntimeStream(boundedWait: boundedWait)
        isReconnectingStream = false
        if discardHistory {
            recentCompletions.removeAll()
            inFlight.removeAll()
            engineErrors.removeAll()
            inspectorEntries.removeAll()
            pendingPrompts.removeAll()
        }
    }

    // MARK: - /api/v1/models polling

    private func startModelsPollTask() {
        guard modelsPollTask == nil else { return }
        modelsPollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.pollModelsOnce()
                guard !Task.isCancelled else { return }
                let interval = self.httpReachable ? self.modelsPollInterval : self.reachabilityPollInterval
                try? await Task.sleep(for: interval)
            }
        }
    }

    private func pollModelsOnce() async {
        guard controller.phase != .tornDown else { return }
        do {
            let response = try await fetchModels()
            let wasUnreachable = !httpReachable
            consecutiveModelsPollFailures = 0
            httpReachable = true
            hasCompletedFirstModelsPoll = true
            applyModelsResponse(response)
            if wasUnreachable, controller.phase == .active {
                logger.notice("pollModelsOnce: server reachable again; resuming full cadence")
                cliAvailable = cliExecutableURLProvider() != nil
                if let cliURL = cliExecutableURLProvider() {
                    if modelStreamProcess == nil { spawnModelStream(executableURL: cliURL) }
                    if runtimeStreamProcess == nil { spawnRuntimeStream(executableURL: cliURL) }
                    startPsPollTask()
                }
            }
        } catch {
            hasCompletedFirstModelsPoll = true
            consecutiveModelsPollFailures += 1
            if consecutiveModelsPollFailures >= 2, httpReachable {
                httpReachable = false
                logger.notice("pollModelsOnce: server unreachable after 2 consecutive failures; backing off")
                stopPsPollTask()
                terminateModelStream(boundedWait: false)
                terminateRuntimeStream(boundedWait: false)
                isReconnectingStream = false
            }
        }
    }

    private func applyModelsResponse(_ response: LMStudioModelsResponse) {
        var loaded: [LMStudioLoadedModelSummary] = []
        var contextLengths: [String: Int] = [:]
        var loadedCount = 0
        for model in response.models {
            guard !model.loadedInstances.isEmpty else { continue }
            loadedCount += 1
            for instance in model.loadedInstances {
                loaded.append(
                    LMStudioLoadedModelSummary(
                        instanceID: instance.id,
                        modelKey: model.key,
                        displayName: model.displayName,
                        publisher: model.publisher,
                        quantizationName: model.quantization?.name,
                        paramsString: model.paramsString,
                        sizeBytes: model.sizeBytes,
                        contextLength: instance.config.contextLength,
                        parallel: instance.config.parallel
                    )
                )
                if let contextLength = instance.config.contextLength {
                    contextLengths[instance.id] = contextLength
                }
            }
        }
        loadedModels = loaded
        catalogCount = response.models.count - loadedCount
        contextLengthByModelIdentifier = contextLengths
        lastModelsPollAt = Date()
    }

    // MARK: - lms ps polling

    private func startPsPollTask() {
        guard psPollTask == nil, cliAvailable else { return }
        psPollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.pollPsOnce()
                guard !Task.isCancelled else { return }
                try? await Task.sleep(for: self.psPollInterval)
            }
        }
    }

    private func stopPsPollTask() {
        psPollTask?.cancel()
        psPollTask = nil
    }

    private func pollPsOnce() async {
        guard let cliURL = cliExecutableURLProvider() else { return }
        do {
            let entries = try await fetchPsEntries(cliURL)
            let sampledAt = Date()
            // Review round 1, S1: `lms ps --json` is external, drifting
            // input — `uniqueKeysWithValues:` traps on a duplicate
            // `identifier`, which would crash the app on exactly the kind
            // of version-drifted/unexpected output this dashboard commits
            // to tolerating rather than crashing on. `uniquingKeysWith:`
            // keeps the latest entry for a repeated identifier instead.
            psByIdentifier = Dictionary(entries.map { ($0.identifier, $0) }, uniquingKeysWith: { _, latest in latest })
            evictStaleInFlight()
            inFlight.removeAll { candidate in
                entries.contains { entry in
                    Self.shouldEvictInFlight(
                        candidateModelIdentifier: candidate.modelIdentifier,
                        candidateStartedAt: candidate.startedAt,
                        psEntry: entry,
                        sampledAt: sampledAt
                    )
                }
            }
        } catch {
            logger.error("pollPsOnce: failed \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The `lms ps` cross-check, gated on the sample's own timestamp versus
    /// the in-flight entry's recorded start time — design doc §5's
    /// phase-2 obligation, implemented here rather than deferred further.
    /// `lms ps` itself takes ~130-160 ms to return (design doc §1.7), so a
    /// sample reporting "idle" can predate a prediction that started
    /// moments before the sample was taken; only clear an in-flight row if
    /// it started strictly before this sample was taken. `internal` (not
    /// `private`) and pure/synchronous so it's directly unit-testable
    /// without driving the async poll loop or a real subprocess —
    /// `LMStudioDashboardPaneContentTests` exercises this in isolation.
    nonisolated static func shouldEvictInFlight(
        candidateModelIdentifier: String,
        candidateStartedAt: Date,
        psEntry: LMStudioPsEntry,
        sampledAt: Date
    ) -> Bool {
        psEntry.isIdle
            && psEntry.identifier == candidateModelIdentifier
            && candidateStartedAt < sampledAt
    }

    // MARK: - Model-source log stream

    private func spawnModelStream(executableURL: URL) {
        guard modelStreamProcess == nil else { return }
        let process = makeModelStreamProcess(executableURL)
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        // Review round 1, B1: a FileHandle read source stays permanently
        // readable once the child closes its end, so a handler that never
        // clears itself at EOF re-enters forever once the process exits —
        // reproduced live as 2.2M invocations in 2 seconds, a permanent
        // full-core busy-spin. Discarding stderr's bytes is not enough; the
        // handler must nil itself out on an empty read exactly like
        // stdout's does below.
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
        }
        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            Task { @MainActor [weak self] in
                self?.ingestModelStreamData(data)
            }
        }
        process.terminationHandler = { [weak self] proc in
            Task { @MainActor [weak self] in
                self?.handleModelStreamTermination(status: proc.terminationStatus)
            }
        }
        do {
            try process.run()
            modelStreamProcess = process
            isReconnectingStream = false
            logger.info("spawnModelStream: started pid=\(process.processIdentifier, privacy: .public)")
        } catch {
            logger.error("spawnModelStream: failed to launch: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func terminateModelStream(boundedWait: Bool) {
        guard let process = modelStreamProcess else { return }
        // Review round 1, S2: this flag must be set here, after the guard
        // — not by the caller before calling this function. If it were set
        // unconditionally by the caller and this guard then early-returned
        // (process already nil — already terminated, or never spawned),
        // the flag would stick `true` forever with nothing left to consume
        // it, silently misreading the *next* genuine unexpected exit as
        // expected: no respawn, no `.reconnecting`, pill still reads
        // "Connected", live feed silently dead until hide/show.
        expectingModelStreamExit = true
        // Clear both handlers explicitly rather than waiting for EOF to
        // arrive asynchronously after `terminate()` — belt-and-suspenders
        // alongside the EOF-based clearing in the readabilityHandler
        // closures themselves (review round 1, B1).
        process.standardOutput.map { ($0 as? Pipe)?.fileHandleForReading.readabilityHandler = nil }
        process.standardError.map { ($0 as? Pipe)?.fileHandleForReading.readabilityHandler = nil }
        process.terminate()
        if boundedWait {
            waitBounded(for: process, label: "model-stream")
        }
        modelStreamProcess = nil
    }

    private func ingestModelStreamData(_ data: Data) {
        modelStreamBuffer.append(data)
        consumeLines(from: &modelStreamBuffer) { [weak self] line in
            self?.handleModelStreamLine(line)
        }
    }

    private func handleModelStreamLine(_ line: String) {
        guard let event = LMStudioLogLineParser.parse(line) else { return }
        switch event.kind {
        case .predictionInput(let modelIdentifier, let rawText):
            recordInFlight(modelIdentifier: modelIdentifier, timestamp: event.timestamp, promptText: rawText)
        case .predictionOutput(let modelIdentifier, let stats, let rawText):
            recordCompletion(modelIdentifier: modelIdentifier, stats: stats, completionText: rawText)
        case .runtimeLog, .other:
            break
        }
    }

    private func recordInFlight(modelIdentifier: String, timestamp: Int64, promptText: String?) {
        let entry = LMStudioInFlightRequest(
            id: UUID(),
            modelIdentifier: modelIdentifier,
            startedAt: Date(timeIntervalSince1970: Double(timestamp) / 1000)
        )
        inFlight.insert(entry, at: 0)
        if promptInspectorEnabled, let promptText {
            pendingPrompts[entry.id] = promptText
        }
        evictStaleInFlight()
    }

    /// Pairs by `modelIdentifier` in arrival order — the oldest unmatched
    /// `input` for this model — the same heuristic design doc §1.4/§4
    /// documents as observed to actually mispair under concurrent
    /// requests, not merely a theoretical risk. There is no request ID to
    /// pair on more reliably (confirmed absent from every source checked,
    /// design doc §1.3/§1.8).
    private func recordCompletion(modelIdentifier: String, stats: LMStudioPredictionStats?, completionText: String?) {
        var promptText: String?
        if let index = inFlight.lastIndex(where: { $0.modelIdentifier == modelIdentifier }) {
            let matched = inFlight.remove(at: index)
            promptText = pendingPrompts.removeValue(forKey: matched.id)
        }

        let contextPressure: Double? = {
            guard let contextLength = contextLengthByModelIdentifier[modelIdentifier],
                  contextLength > 0,
                  let promptTokens = stats?.promptTokensCount
            else { return nil }
            return Double(promptTokens) / Double(contextLength)
        }()

        let record = LMStudioCompletionRecord(
            id: UUID(),
            completedAt: Date(),
            modelIdentifier: modelIdentifier,
            stats: stats,
            contextPressure: contextPressure
        )
        recentCompletions.insert(record, at: 0)
        if recentCompletions.count > Self.completionCap {
            recentCompletions.removeLast(recentCompletions.count - Self.completionCap)
        }

        if promptInspectorEnabled {
            let inspectorRecord = LMStudioInspectorRecord(
                id: record.id,
                modelIdentifier: modelIdentifier,
                completedAt: record.completedAt,
                prompt: promptText,
                completion: completionText
            )
            inspectorEntries.insert(inspectorRecord, at: 0)
            if inspectorEntries.count > Self.inspectorCap {
                inspectorEntries.removeLast(inspectorEntries.count - Self.inspectorCap)
            }
        }
    }

    private func evictStaleInFlight() {
        let cutoff = Date().addingTimeInterval(-staleInFlightWindow)
        let staleIDs = Set(inFlight.filter { $0.startedAt < cutoff }.map(\.id))
        guard !staleIDs.isEmpty else { return }
        inFlight.removeAll { staleIDs.contains($0.id) }
        for id in staleIDs { pendingPrompts.removeValue(forKey: id) }
    }

    private func handleModelStreamTermination(status: Int32) {
        modelStreamProcess = nil
        guard !expectingModelStreamExit else {
            expectingModelStreamExit = false
            return
        }
        logger.notice("model-stream exited unexpectedly status=\(status, privacy: .public)")
        scheduleRespawn(of: .model)
    }

    // MARK: - Runtime-source log stream (Engine Errors panel)

    private func spawnRuntimeStream(executableURL: URL) {
        guard runtimeStreamProcess == nil else { return }
        let process = makeRuntimeStreamProcess(executableURL)
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        // Review round 1, B1: a FileHandle read source stays permanently
        // readable once the child closes its end, so a handler that never
        // clears itself at EOF re-enters forever once the process exits —
        // reproduced live as 2.2M invocations in 2 seconds, a permanent
        // full-core busy-spin. Discarding stderr's bytes is not enough; the
        // handler must nil itself out on an empty read exactly like
        // stdout's does below.
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
        }
        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            Task { @MainActor [weak self] in
                self?.ingestRuntimeStreamData(data)
            }
        }
        process.terminationHandler = { [weak self] proc in
            Task { @MainActor [weak self] in
                self?.handleRuntimeStreamTermination(status: proc.terminationStatus)
            }
        }
        do {
            try process.run()
            runtimeStreamProcess = process
            logger.info("spawnRuntimeStream: started pid=\(process.processIdentifier, privacy: .public)")
        } catch {
            logger.error("spawnRuntimeStream: failed to launch: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func terminateRuntimeStream(boundedWait: Bool) {
        guard let process = runtimeStreamProcess else { return }
        // See terminateModelStream's comment (review round 1, S2): this
        // flag must be set here, after the guard, not by the caller.
        expectingRuntimeStreamExit = true
        // See terminateModelStream's comment: both handlers must be
        // cleared explicitly, not just stdout's.
        process.standardOutput.map { ($0 as? Pipe)?.fileHandleForReading.readabilityHandler = nil }
        process.standardError.map { ($0 as? Pipe)?.fileHandleForReading.readabilityHandler = nil }
        process.terminate()
        if boundedWait {
            waitBounded(for: process, label: "runtime-stream")
        }
        runtimeStreamProcess = nil
    }

    private func ingestRuntimeStreamData(_ data: Data) {
        runtimeStreamBuffer.append(data)
        consumeLines(from: &runtimeStreamBuffer) { [weak self] line in
            self?.handleRuntimeStreamLine(line)
        }
    }

    private func handleRuntimeStreamLine(_ line: String) {
        guard let event = LMStudioLogLineParser.parse(line),
              case .runtimeLog(let level, let message, let engineName) = event.kind
        else { return }
        let entry = LMStudioEngineLogEntry(
            id: UUID(),
            timestamp: event.date,
            level: level,
            message: message,
            engineName: engineName
        )
        engineErrors.insert(entry, at: 0)
        if engineErrors.count > Self.engineErrorCap {
            engineErrors.removeLast(engineErrors.count - Self.engineErrorCap)
        }
    }

    private func handleRuntimeStreamTermination(status: Int32) {
        runtimeStreamProcess = nil
        guard !expectingRuntimeStreamExit else {
            expectingRuntimeStreamExit = false
            return
        }
        logger.notice("runtime-stream exited unexpectedly status=\(status, privacy: .public)")
        scheduleRespawn(of: .runtime)
    }

    // MARK: - Respawn

    private enum StreamKind {
        case model
        case runtime
    }

    private func scheduleRespawn(of kind: StreamKind) {
        guard controller.phase == .active, httpReachable else { return }
        isReconnectingStream = true
        Task { [weak self] in
            try? await Task.sleep(for: self?.respawnDelay ?? .seconds(2))
            guard let self, self.controller.phase == .active, self.httpReachable else { return }
            guard let cliURL = self.cliExecutableURLProvider() else { return }
            switch kind {
            case .model: self.spawnModelStream(executableURL: cliURL)
            case .runtime: self.spawnRuntimeStream(executableURL: cliURL)
            }
            self.isReconnectingStream = (self.modelStreamProcess == nil || self.runtimeStreamProcess == nil)
        }
    }

    // MARK: - Helpers

    private func consumeLines(from buffer: inout Data, handler: (String) -> Void) {
        let newline = UInt8(ascii: "\n")
        while let range = buffer.firstRange(of: [newline]) {
            let lineData = buffer[..<range.lowerBound]
            if let line = String(data: lineData, encoding: .utf8) {
                handler(line)
            }
            buffer.removeSubrange(..<range.upperBound)
        }
    }

    /// Sends `SIGTERM` (already done by the caller via `process.terminate()`)
    /// and blocks the calling thread — the main actor, since this class is
    /// `@MainActor` — for at most `teardownWaitBound`, polling
    /// `Process.isRunning`. Design doc §7: `Process.terminate()` alone only
    /// sends the signal and returns immediately, which is not evidence of
    /// release (`#0289`'s lesson); an unbounded `waitUntilExit()` risks
    /// hanging the main actor if a subprocess is ever wedged. `lms` is a
    /// normal CLI process expected to die promptly on `SIGTERM` — this
    /// bound should not be hit in practice.
    private func waitBounded(for process: Process, label: String) {
        let deadline = Date().addingTimeInterval(teardownWaitBound)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            logger.error("teardown: \(label, privacy: .public) did not exit within \(self.teardownWaitBound, privacy: .public)s bound")
        } else {
            logger.info("teardown: \(label, privacy: .public) exited within bound")
        }
    }
}
