// LMStudioDashboardPaneContent.swift

import Darwin
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
    /// Where `scheduleTeardownReap` registers a pending reap so
    /// `applicationWillTerminate` can drain it even after this pane has
    /// left `AppStateStore.windows` (#0425). Defaults to the process-wide
    /// singleton; a test injects a fresh instance so it can't observe
    /// another test's pending reaps.
    public var teardownReapRegistry: PendingTeardownReapRegistry = .shared
    /// Where the models poll, `lms ps` poll, respawn-delay loop, and the
    /// stale-in-flight sweep's own notion of "now" all come from
    /// (`docs/async-test-seams.md` §1, #0428) — defaults to the real clock.
    /// Only `LMStudioDashboardPaneContentTests` overrides it, with
    /// `TestClock`, to drive those loops deterministically instead of
    /// waiting on real time (`AGENTS.md` "Asynchronous tests").
    public var clock: SchedulingClock = SystemClock()
    /// Gates `scheduleTeardownReap`'s detached wait/`SIGKILL` escalation
    /// (`docs/async-test-seams.md` §3, #0428) — defaults to always-open in
    /// production. A test holds this closed to prove `tearDown()` returns
    /// without blocking on the reap, structurally, rather than by timing
    /// the call.
    public var reapGate: TeardownReapGate = OpenTeardownReapGate()

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
    /// Bound on how long `tearDown()` waits, off the main actor, for a
    /// subprocess to exit after `SIGTERM` before escalating to `SIGKILL`
    /// (#0354), per design doc §7's "a few hundred milliseconds" — matching
    /// `#0289`'s lesson that a log line is not evidence of release,
    /// generalized to subprocess exit. `setVisible(false)` (hiding) sends
    /// `SIGTERM` only and does not wait at all, per design doc §7's table.
    public var teardownWaitBound: TimeInterval = 0.5

    public static let completionCap = BellFeedStore.cap
    public static let inspectorCap = 5
    public static let engineErrorCap = 50
    /// Hard cap on `inFlight`, independent of `staleInFlightWindow`'s
    /// time-based sweep (issue #0355). Design doc §6 expects low single
    /// digits in normal operation — bounded by each loaded instance's own
    /// `parallel` config — so this cap only bites under a burst or a
    /// pairing-heuristic failure (§1.4) that leaves entries stuck
    /// unmatched. Sized generously above that expectation (`engineErrorCap`'s
    /// order of magnitude, reused rather than inventing a new one). With
    /// the Prompt Inspector on, each entry's `pendingPrompts` text is
    /// itself bounded by `streamLineByteCap` (the whole NDJSON line it came
    /// from), so `inFlightCap × streamLineByteCap` ≈ 12.5 MB is the true
    /// worst-case ceiling on retained prompt text — the typical case, per
    /// §1.5's tens-of-KB-per-prompt figures, is far smaller than that
    /// ceiling, but the ceiling is the number that actually bounds memory.
    public static let inFlightCap = 50
    /// Hard byte cap per NDJSON line (issue #0355) — bounds both a single
    /// enormous line (a `-s model` line carries the full prompt, §1.5) and
    /// a malformed/adversarial stream that never emits `\n`. An order of
    /// magnitude above the largest event size this document's own spike
    /// actually measured live (18,257 bytes, §1.5 — the reference's ~28 KB
    /// figure for a real OpenCode turn was carried forward there as
    /// unverified at that magnitude, not independently confirmed), so it
    /// never trips on real traffic.
    public static let streamLineByteCap = 256 * 1024

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

    var warningsAndErrors: [LMStudioEngineLogEntry] {
        LMStudioDashboardFormatting.warningsAndErrors(engineErrors)
    }
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
    private var modelStreamBuffer = NDJSONLineBuffer()
    private var runtimeStreamBuffer = NDJSONLineBuffer()
    private var expectingModelStreamExit = false
    private var expectingRuntimeStreamExit = false

    private var modelsPollTask: Task<Void, Never>?
    private var psPollTask: Task<Void, Never>?
    /// Detached reap tasks `tearDown()` has scheduled (#0354) — kept so
    /// `awaitPendingTeardownReapsForTesting()` can await them deterministically.
    private var pendingTeardownReapTasks: [Task<Void, Never>] = []
    /// The `(process, label)` pairs backing `pendingTeardownReapTasks`,
    /// tracked separately so `waitForDeferredTeardown()` (`DeferredTeardownWaiting`,
    /// below) can re-run the same bounded wait/`SIGKILL` synchronously on
    /// the calling thread for the quit path, which cannot rely on the
    /// detached tasks above ever getting scheduled before the process exits.
    private var pendingTeardownReaps: [(process: Process, label: String)] = []

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
        finishTestEventStreams()
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
                await self.clock.sleep(for: interval)
            }
        }
    }

    private func pollModelsOnce() async {
        guard controller.phase != .tornDown else { return }
        defer { emitModelsPollApplied() }
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
                await self.clock.sleep(for: self.psPollInterval)
            }
        }
    }

    private func stopPsPollTask() {
        psPollTask?.cancel()
        psPollTask = nil
    }

    private func pollPsOnce() async {
        guard let cliURL = cliExecutableURLProvider() else { return }
        defer { emitPsPollApplied() }
        do {
            let entries = try await fetchPsEntries(cliURL)
            let sampledAt = clock.now
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
        // A prior process may have left `modelStreamBuffer` mid-drop (a
        // never-terminated oversized line, `isDroppingOversizedLine ==
        // true`) when it exited. That state belongs to the dead process's
        // byte stream, not the new one's — left in place, the new
        // process's first bytes would be read as "the rest of the old
        // line" and silently dropped through its first `\n`.
        modelStreamBuffer = NDJSONLineBuffer()
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
            scheduleTeardownReap(for: process, label: "model-stream")
        }
        modelStreamProcess = nil
    }

    private func ingestModelStreamData(_ data: Data) {
        let result = modelStreamBuffer.append(data, maxLineBytes: Self.streamLineByteCap)
        // One log when a drop starts, one when it ends — never a log per
        // pipe read for however many chunks a never-terminated line spans.
        if result.beganDroppingOversizedLine {
            logger.error("model-stream: line exceeds cap \(Self.streamLineByteCap, privacy: .public) bytes with no newline yet; dropping until next newline")
        }
        for byteCount in result.droppedLineByteCounts {
            logger.error("model-stream: dropped oversized line, \(byteCount, privacy: .public) bytes, cap \(Self.streamLineByteCap, privacy: .public)")
        }
        for line in result.lines {
            handleModelStreamLine(line)
        }
    }

    private func handleModelStreamLine(_ line: String) {
        guard let event = LMStudioLogLineParser.parse(line) else { return }
        defer { emitLineApplied() }
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
        evictOverflowInFlight()
    }

    /// Hard cap independent of `evictStaleInFlight`'s time-based sweep
    /// (issue #0355) — evicts the oldest entries once `inFlightCap` is
    /// exceeded, e.g. under a pairing-heuristic failure (design doc §1.4)
    /// that leaves entries permanently unmatched well before the 5-minute
    /// staleness window would otherwise clear them.
    private func evictOverflowInFlight() {
        guard inFlight.count > Self.inFlightCap else { return }
        let overflow = inFlight.suffix(from: Self.inFlightCap)
        for evicted in overflow { pendingPrompts.removeValue(forKey: evicted.id) }
        let evictedCount = overflow.count
        inFlight.removeLast(evictedCount)
        logger.notice("evictOverflowInFlight: inFlight exceeded cap (\(Self.inFlightCap, privacy: .public)); evicted \(evictedCount, privacy: .public) oldest entries")
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
        let cutoff = clock.now.addingTimeInterval(-staleInFlightWindow)
        let staleIDs = Set(inFlight.filter { $0.startedAt < cutoff }.map(\.id))
        guard !staleIDs.isEmpty else { return }
        inFlight.removeAll { staleIDs.contains($0.id) }
        for id in staleIDs { pendingPrompts.removeValue(forKey: id) }
    }

    private func handleModelStreamTermination(status: Int32) {
        modelStreamProcess = nil
        defer { emitStreamTerminationHandled() }
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
        // See `spawnModelStream`'s identical comment: a prior process may
        // have left `runtimeStreamBuffer` mid-drop; that state does not
        // belong to the new process's byte stream.
        runtimeStreamBuffer = NDJSONLineBuffer()
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
            scheduleTeardownReap(for: process, label: "runtime-stream")
        }
        runtimeStreamProcess = nil
    }

    private func ingestRuntimeStreamData(_ data: Data) {
        let result = runtimeStreamBuffer.append(data, maxLineBytes: Self.streamLineByteCap)
        // See `ingestModelStreamData`'s identical comment: one log when a
        // drop starts, one when it ends, never one per pipe read.
        if result.beganDroppingOversizedLine {
            logger.error("runtime-stream: line exceeds cap \(Self.streamLineByteCap, privacy: .public) bytes with no newline yet; dropping until next newline")
        }
        for byteCount in result.droppedLineByteCounts {
            logger.error("runtime-stream: dropped oversized line, \(byteCount, privacy: .public) bytes, cap \(Self.streamLineByteCap, privacy: .public)")
        }
        for line in result.lines {
            handleRuntimeStreamLine(line)
        }
    }

    private func handleRuntimeStreamLine(_ line: String) {
        guard let event = LMStudioLogLineParser.parse(line) else { return }
        defer { emitLineApplied() }
        guard case .runtimeLog(let level, let message, let engineName) = event.kind else { return }
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
        defer { emitStreamTerminationHandled() }
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
        let delay = respawnDelay
        let clock = clock
        Task { [weak self] in
            await clock.sleep(for: delay)
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

    /// `SIGTERM` is already sent by the caller (`process.terminate()`) before
    /// this is reached. #0354: the bounded wait for the child to actually
    /// exit — and the `SIGKILL` escalation if it doesn't — used to run as a
    /// `Thread.sleep` poll on the calling thread, which was always the main
    /// actor (this class is `@MainActor`), blocking the UI for up to
    /// `teardownWaitBound` per stream (up to ~1s total across both streams
    /// on close). This schedules that same wait-then-escalate work on a
    /// detached `Task` instead, so `tearDown()` itself returns immediately
    /// after sending `SIGTERM` while the reap still completes — verifiable
    /// via `awaitPendingTeardownReapsForTesting()` (async, for tests) or
    /// `waitForDeferredTeardown()` (sync, for the quit path — both below).
    /// The detached task alone is not a complete guarantee: if the whole
    /// app process exits before the task is scheduled, it never runs at
    /// all, which is exactly why the quit path doesn't rely on it.
    private func scheduleTeardownReap(for process: Process, label: String) {
        let bound = teardownWaitBound
        pendingTeardownReaps.append((process, label))
        let registry = teardownReapRegistry
        let token = registry.register(process: process, label: label, bound: bound)
        let gate = reapGate
        let task = Task.detached(priority: .utility) {
            await gate.waitUntilOpen()
            Self.reapAfterTerminate(process, bound: bound, label: label)
            registry.deregister(token)
        }
        pendingTeardownReapTasks.append(task)
    }

    /// Runs entirely off the main actor (or, via `waitForDeferredTeardown()`,
    /// synchronously on whatever thread calls it — this function itself has
    /// no actor affinity). Polls `Process.isRunning` for at most `bound` —
    /// `Process` has no async "did it exit" API — then sends `SIGKILL` if
    /// the child is still alive, so the "actually reaped" guarantee
    /// (`docs/pane-view-lifecycle.md` §5) does not depend on the child's
    /// own cooperation with `SIGTERM`. `lms` is a normal CLI process
    /// expected to die promptly on `SIGTERM` — the escalation is for the
    /// case where it doesn't, not the expected path.
    ///
    /// Returns only after the child is observed exited, not just signaled:
    /// `SIGKILL` only requests the exit, and `Process.isRunning` flips only
    /// once Foundation's own exit-monitoring source observes it (`waitpid`
    /// internally — never called directly here, Foundation owns that). The
    /// second bounded poll after `SIGKILL` below is what makes that true;
    /// without it, a caller finishing on this function (or the `Task`
    /// wrapping it) could observe completion before the child had actually
    /// exited.
    nonisolated private static func reapAfterTerminate(_ process: Process, bound: TimeInterval, label: String) {
        let deadline = Date().addingTimeInterval(bound)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        guard process.isRunning else {
            logger.info("teardown: \(label, privacy: .public) exited within bound")
            return
        }
        logger.error("teardown: \(label, privacy: .public) did not exit within \(bound, privacy: .public)s bound; sending SIGKILL")
        kill(process.processIdentifier, SIGKILL)
        let killDeadline = Date().addingTimeInterval(min(bound, 0.5))
        while process.isRunning, Date() < killDeadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            logger.error("teardown: \(label, privacy: .public) still running after SIGKILL")
        } else {
            logger.info("teardown: \(label, privacy: .public) exited after SIGKILL")
        }
    }

    // MARK: - Test support

    /// Awaits every reap task scheduled by `tearDown()` so far, then clears
    /// the list. `internal`, not `private`, so `LMStudioDashboardPaneContentTests`
    /// can observe the "eventually killed/reaped" half of #0354's fix
    /// deterministically instead of polling `Process.isRunning` on a fixed
    /// sleep — the same "internal for testability" reasoning
    /// `shouldEvictInFlight` above documents for itself. Never called from
    /// production code.
    func awaitPendingTeardownReapsForTesting() async {
        let tasks = pendingTeardownReapTasks
        pendingTeardownReapTasks.removeAll()
        pendingTeardownReaps.removeAll()
        for task in tasks {
            await task.value
        }
    }

    // MARK: - Test support (completion events; #0429)
    //
    // Four `AsyncStream<Void>` signals, one per unit of asynchronous work a
    // test needs to await instead of sleeping (`docs/async-test-seams.md`
    // §4's "AsyncStream of events" shape). Each yields once per completed
    // occurrence of the work it names; a test counts the occurrences it
    // cares about. `internal`, not `private`, so
    // `LMStudioDashboardPaneContentTests` can subscribe via `@testable
    // import`. Never subscribed to in production — creating one of these
    // streams has no effect on when or whether the underlying work runs.

    private var modelsPollAppliedContinuations: [UUID: AsyncStream<Void>.Continuation] = [:]
    private var psPollAppliedContinuations: [UUID: AsyncStream<Void>.Continuation] = [:]
    private var lineAppliedContinuations: [UUID: AsyncStream<Void>.Continuation] = [:]
    private var streamTerminationHandledContinuations: [UUID: AsyncStream<Void>.Continuation] = [:]

    /// Yields once every time `pollModelsOnce()` completes an attempt,
    /// success or failure.
    func modelsPollAppliedEventsForTesting() -> AsyncStream<Void> {
        makeTestEventStream(.modelsPollApplied)
    }

    /// Yields once every time `pollPsOnce()` completes an attempt, success
    /// or failure.
    func psPollAppliedEventsForTesting() -> AsyncStream<Void> {
        makeTestEventStream(.psPollApplied)
    }

    /// Yields once for every parseable NDJSON line applied by
    /// `handleModelStreamLine` (`recordInFlight`/`recordCompletion`, or a
    /// no-op for a non-prediction event) or `handleRuntimeStreamLine`
    /// (engine log insert, or a no-op for a non-`.runtimeLog` event).
    /// Unparseable lines never fire it. Lets a test await a specific count
    /// of lines the pipe has actually processed, rather than guessing how
    /// long delivery takes.
    func lineAppliedEventsForTesting() -> AsyncStream<Void> {
        makeTestEventStream(.lineApplied)
    }

    /// Yields once every time `handleModelStreamTermination`/
    /// `handleRuntimeStreamTermination` finishes handling an exit —
    /// expected (this pane's own `terminate()`) or unexpected. An
    /// unexpected exit only *schedules* a respawn when `scheduleRespawn`'s
    /// own guard passes (`controller.phase == .active && httpReachable`);
    /// this event fires either way, since it marks "the termination was
    /// handled," not "a respawn was scheduled."
    func streamTerminationHandledEventsForTesting() -> AsyncStream<Void> {
        makeTestEventStream(.streamTerminationHandled)
    }

    /// Which of the four continuation dictionaries a `makeTestEventStream`
    /// subscription belongs to. A plain, associated-value-free enum (and so
    /// implicitly `Sendable`) rather than a `KeyPath`: `KeyPath` isn't
    /// `Sendable`, so it can't be captured by `onTermination`'s `@Sendable`
    /// closure below.
    private enum TestEventKind {
        case modelsPollApplied, psPollApplied, lineApplied, streamTerminationHandled
    }

    private func insertTestEventContinuation(_ kind: TestEventKind, id: UUID, _ continuation: AsyncStream<Void>.Continuation) {
        switch kind {
        case .modelsPollApplied: modelsPollAppliedContinuations[id] = continuation
        case .psPollApplied: psPollAppliedContinuations[id] = continuation
        case .lineApplied: lineAppliedContinuations[id] = continuation
        case .streamTerminationHandled: streamTerminationHandledContinuations[id] = continuation
        }
    }

    private func removeTestEventContinuation(_ kind: TestEventKind, id: UUID) {
        switch kind {
        case .modelsPollApplied: modelsPollAppliedContinuations.removeValue(forKey: id)
        case .psPollApplied: psPollAppliedContinuations.removeValue(forKey: id)
        case .lineApplied: lineAppliedContinuations.removeValue(forKey: id)
        case .streamTerminationHandled: streamTerminationHandledContinuations.removeValue(forKey: id)
        }
    }

    /// Builds one of the four test-only `AsyncStream<Void>` signals above,
    /// keyed by a fresh `UUID` so `onTermination` can remove exactly this
    /// subscription — e.g. when the test that created it goes out of scope
    /// and its `AsyncStream` (and the `EventCounter` consuming it) is
    /// deallocated — without disturbing any other test's still-live
    /// subscription to the same signal. `tearDown()`'s `finishTestEventStreams()`
    /// additionally `finish()`es every remaining subscription outright, so a
    /// test's `for await` consumer loop (`EventCounter`'s `consumeTask`)
    /// ends on its own once this pane tears down, rather than only ever
    /// being force-cancelled by that consumer's own `deinit`.
    private func makeTestEventStream(_ kind: TestEventKind) -> AsyncStream<Void> {
        let id = UUID()
        return AsyncStream { continuation in
            insertTestEventContinuation(kind, id: id, continuation)
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.removeTestEventContinuation(kind, id: id)
                }
            }
        }
    }

    private func emitModelsPollApplied() {
        for continuation in modelsPollAppliedContinuations.values { continuation.yield() }
    }

    private func emitPsPollApplied() {
        for continuation in psPollAppliedContinuations.values { continuation.yield() }
    }

    private func emitLineApplied() {
        for continuation in lineAppliedContinuations.values { continuation.yield() }
    }

    private func emitStreamTerminationHandled() {
        for continuation in streamTerminationHandledContinuations.values { continuation.yield() }
    }

    /// Finishes and clears every pending test-event subscription — called
    /// from `tearDown()` so a test's `for await` consumer (`EventCounter`)
    /// ends cleanly once this pane tears down, instead of only ever being
    /// force-cancelled by the consumer's own `deinit`.
    private func finishTestEventStreams() {
        for continuation in modelsPollAppliedContinuations.values { continuation.finish() }
        modelsPollAppliedContinuations.removeAll()
        for continuation in psPollAppliedContinuations.values { continuation.finish() }
        psPollAppliedContinuations.removeAll()
        for continuation in lineAppliedContinuations.values { continuation.finish() }
        lineAppliedContinuations.removeAll()
        for continuation in streamTerminationHandledContinuations.values { continuation.finish() }
        streamTerminationHandledContinuations.removeAll()
    }
}

/// Adopted by a `PaneContentLifecycle` conformer whose `tearDown()` defers
/// part of its release work to a background task —
/// `LMStudioDashboardPaneContent` (#0354's detached subprocess reap) and
/// `GitStatusPaneContent` (#0422's, via `ProcessGitStatusScanner`) both
/// adopt it. `tearDown()` returning is not, by itself, proof that work has
/// finished, and for most callers that's fine (the whole point is not
/// blocking them on it). The one exception is quitting the app:
/// `BattyAppDelegate.applicationWillTerminate` runs synchronously and the
/// process exits shortly after it returns, so a detached reap task
/// scheduled inside it may never get to run at all — silently orphaning a
/// subprocess `SIGTERM` failed to kill. `WindowRuntime` checks for this
/// conformance on the quit path only and blocks briefly instead, which is
/// an acceptable trade there (the app is exiting anyway) and nowhere else
/// in the lifecycle.
///
/// This walk only reaches a reap whose owning pane is still reachable from
/// `AppStateStore.windows` at quit time. `PendingTeardownReapRegistry`
/// (#0425) covers what this walk cannot: a reap left behind by a pane, tab,
/// session, or window closed (and already removed from the model) moments
/// before quit. Both conformers register there too, in `scheduleTeardownReap`.
protocol DeferredTeardownWaiting: AnyObject {
    /// Blocks the calling thread until every reap `tearDown()` scheduled has
    /// actually completed (escalating to `SIGKILL` exactly as `tearDown()`
    /// itself would, on the same bound). Idempotent: a conformer with
    /// nothing pending returns immediately. Every `SIGTERM` was already
    /// sent before `tearDown()` returned, so a cooperative child adds
    /// nothing here; the worst case is one `SIGTERM`-ignoring subprocess
    /// taking up to `bound + min(bound, 0.5)`, waited sequentially per
    /// subprocess this conformer owns: ≈1.0s per stream (≈2.0s worst case
    /// across its two streams) at `LMStudioDashboardPaneContent`'s 0.5s
    /// default; ≈0.6s per tracked `git` subprocess at
    /// `ProcessGitStatusScanner`'s 0.3s default (`GitStatusPaneContent` —
    /// usually one, but a scan and a `diff` can overlap).
    func waitForDeferredTeardown()
}

extension LMStudioDashboardPaneContent: DeferredTeardownWaiting {
    func waitForDeferredTeardown() {
        let pending = pendingTeardownReaps
        pendingTeardownReaps.removeAll()
        pendingTeardownReapTasks.removeAll()
        for (process, label) in pending {
            Self.reapAfterTerminate(process, bound: teardownWaitBound, label: label)
        }
    }
}

/// Incrementally reassembles `\n`-terminated NDJSON lines from a
/// subprocess's stdout. Invariant: one forward scan over `data` per
/// `append`, draining every complete line it finds with a single
/// `removeSubrange` for the whole batch, never one `removeSubrange` per
/// line. `internal`, not `private`, so `LMStudioDashboardPaneContentTests`
/// can drive it directly with synthetic byte sequences.
struct NDJSONLineBuffer {
    struct AppendResult {
        var lines: [String] = []
        /// True exactly once — the call where a still-open line first
        /// exceeds `maxLineBytes` with no terminator found yet. The
        /// caller logs this once and does not log again while the same
        /// drop continues across further `append` calls with no `\n` —
        /// a never-terminated line must not log on every pipe read.
        var beganDroppingOversizedLine = false
        /// One entry per line dropped for exceeding `maxLineBytes`,
        /// *completed* within this call — either found together with its
        /// own terminator in one pass, or the tail end of a run that
        /// began in an earlier call. Each value is that line's full size,
        /// including any bytes dropped in earlier calls for the same line.
        var droppedLineByteCounts: [Int] = []
        var droppedLineCount: Int { droppedLineByteCounts.count }
        var droppedByteCount: Int { droppedLineByteCounts.reduce(0, +) }
    }

    private var data = Data()
    /// Set once the bytes since the last newline exceeded `maxLineBytes`
    /// with no terminator yet found. While set, every subsequent `append`
    /// discards its bytes outright (never re-accumulating past the cap)
    /// until the next `\n` arrives, at which point the offending run is
    /// dropped as a whole and normal line extraction resumes on whatever
    /// follows — "resynchronizes at the next newline."
    private var isDroppingOversizedLine = false
    /// Cumulative size of the line currently being dropped, across
    /// however many `append` calls it has spanned so far — reported as a
    /// single total once its `\n` finally arrives, not per call.
    private var droppingRunByteCount = 0

    mutating func append(_ chunk: Data, maxLineBytes: Int) -> AppendResult {
        data.append(chunk)
        var result = AppendResult()
        let newline = UInt8(ascii: "\n")

        if isDroppingOversizedLine {
            if let newlineIndex = data.firstIndex(of: newline) {
                droppingRunByteCount += data.distance(from: data.startIndex, to: newlineIndex) + 1
                result.droppedLineByteCounts.append(droppingRunByteCount)
                data.removeSubrange(data.startIndex...newlineIndex)
                isDroppingOversizedLine = false
                droppingRunByteCount = 0
            } else {
                droppingRunByteCount += data.count
                data.removeAll(keepingCapacity: true)
                return result
            }
        }

        var consumedUpTo = data.startIndex
        while let newlineIndex = data[consumedUpTo...].firstIndex(of: newline) {
            let lineRange = consumedUpTo..<newlineIndex
            if lineRange.count > maxLineBytes {
                result.droppedLineByteCounts.append(lineRange.count)
            } else if let line = String(data: data[lineRange], encoding: .utf8) {
                result.lines.append(line)
            }
            consumedUpTo = data.index(after: newlineIndex)
        }
        if consumedUpTo > data.startIndex {
            data.removeSubrange(data.startIndex..<consumedUpTo)
        }

        if data.count > maxLineBytes {
            droppingRunByteCount = data.count
            data.removeAll(keepingCapacity: true)
            isDroppingOversizedLine = true
            result.beganDroppingOversizedLine = true
        }

        return result
    }
}
