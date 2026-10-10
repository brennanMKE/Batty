// LMStudioDashboardPaneContentTests.swift

import Darwin
import Foundation
import Testing
@testable import BattyKit

/// Drives `LMStudioDashboardPaneContent` through its degraded states
/// (not-installed, unreachable, reconnecting) and its subprocess-parsing
/// pipeline, entirely through injected fakes — no real `lms` CLI or LM
/// Studio server required, per `docs/pane-view-lifecycle.md` §6's
/// "testable without GUI access" mandate. Every process the fakes launch
/// is a plain `/bin/sh` one-liner standing in for `lms log stream`, so the
/// real pipe → NDJSON-parse → observable-state path is exercised end to
/// end, not just mocked away.
@MainActor
struct LMStudioDashboardPaneContentTests {

    /// `exec` (not a bare `sleep 60`) keeps this a single process: without
    /// it, `sleep` runs as `sh`'s forked child, and `terminate()`'s
    /// `SIGTERM` — which only reaches `sh`'s pid — kills `sh` without
    /// forwarding the signal, orphaning `sleep` for up to its own 60s
    /// lifetime.
    private func makeSleepForeverProcess(_ url: URL) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "exec sleep 60"]
        return process
    }

    /// Current epoch milliseconds — the fixtures below must use a live
    /// timestamp, not a captured one: `staleInFlightWindow` defaults to
    /// 5 minutes, and a fixture frozen at whatever moment it was captured
    /// live against the real server would immediately fail the staleness
    /// check the instant "now" drifts more than 5 minutes past it.
    private func nowMillis() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    private func predictionInputLine(modelIdentifier: String, timestamp: Int64) -> String {
        #"{"timestamp":\#(timestamp),"data":{"type":"llm.prediction.input","input":"hi","modelIdentifier":"\#(modelIdentifier)"}}"#
    }

    private func predictionOutputLine(modelIdentifier: String, timestamp: Int64) -> String {
        #"{"timestamp":\#(timestamp),"data":{"type":"llm.prediction.output","output":"pong","stats":{"stopReason":"eosFound","tokensPerSecond":100,"promptTokensCount":5,"predictedTokensCount":1},"modelIdentifier":"\#(modelIdentifier)"}}"#
    }

    private func emptyModelsResponse() -> LMStudioModelsResponse {
        LMStudioModelsResponse(models: [])
    }

    // MARK: - Not installed

    @Test func notInstalledWhenCLIMissingButModelsPollStillWorksOverHTTP() async throws {
        let content = LMStudioDashboardPaneContent()
        content.clock = TestClock()
        content.cliExecutableURLProvider = { nil }
        content.fetchModels = {
            LMStudioModelsResponse(models: [
                LMStudioModelInfo(
                    type: "llm", key: "m", displayName: "M", publisher: "p",
                    architecture: nil, quantization: nil, sizeBytes: nil,
                    paramsString: nil, format: nil,
                    loadedInstances: [LMStudioLoadedInstance(id: "m", config: LMStudioInstanceConfig(contextLength: 4096, parallel: 1))],
                    maxContextLength: nil
                ),
            ])
        }
        let modelsPollApplied = EventCounter(content.modelsPollAppliedEventsForTesting())

        content.setUp(visible: true)
        guard await modelsPollApplied.awaitCount(1) else {
            Issue.record("models poll never applied")
            content.tearDown()
            return
        }

        #expect(content.connectionState == .notInstalled)
        #expect(content.loadedModels.count == 1)
        #expect(content.loadedModels.first?.displayName == "M")

        content.tearDown()
    }

    // MARK: - Unreachable (two-strike rule)

    @Test func unreachableAfterTwoConsecutiveModelsPollFailures() async throws {
        struct Failure: Error {}
        let content = LMStudioDashboardPaneContent()
        let clock = TestClock()
        content.clock = clock
        content.cliExecutableURLProvider = { URL(fileURLWithPath: "/nonexistent/lms") }
        content.makeModelStreamProcess = makeSleepForeverProcess
        content.makeRuntimeStreamProcess = makeSleepForeverProcess
        content.fetchModels = { throw Failure() }
        let modelsPollApplied = EventCounter(content.modelsPollAppliedEventsForTesting())

        content.setUp(visible: true)
        // `setUp(visible: true)` schedules two independent first attempts —
        // `setUp`'s own one-shot poll and `startModelsPollTask`'s loop's
        // first iteration — so two completed poll attempts land without the
        // loop's own interval ever needing to elapse. `consecutiveModelsPollFailures`
        // is incremented once per completed attempt regardless of which
        // task produced it (both run sequentially on this actor), so
        // counting two of this event is enough to have crossed
        // `pollModelsOnce`'s own `>= 2` threshold — `oneModelsPollFailureDoesNotYetReportUnreachable`
        // below is the complementary proof that *one* completed attempt is
        // not enough.
        guard await modelsPollApplied.awaitCount(2) else {
            Issue.record("did not observe two completed models-poll attempts")
            content.tearDown()
            await content.awaitPendingTeardownReapsForTesting()
            return
        }

        #expect(content.connectionState == .unreachable)

        content.tearDown()
        // Real subprocesses (`makeSleepForeverProcess`) — awaiting the reap
        // here, as every test that spawns one now must, is what keeps this
        // suite from leaking a live `sleep` process past the test's own
        // lifetime (#0354's detached reap doesn't run synchronously inside
        // `tearDown()` any more).
        await content.awaitPendingTeardownReapsForTesting()
    }

    /// The complementary half of the two-strike rule: exactly one failed
    /// poll must not yet report `.unreachable`. `setUp(visible: false)`
    /// keeps this to exactly one attempt with no ambiguity about which task
    /// produced it — `startActiveWork()` (and so `startModelsPollTask`'s
    /// loop) never runs when `visible` is `false`, so only `setUp`'s own
    /// one-shot `pollModelsOnce()` call fires, and no real subprocess or
    /// clock advance is needed at all. `refreshNow()` then drives a second,
    /// equally unambiguous attempt to observe the actual flip.
    @Test func oneModelsPollFailureDoesNotYetReportUnreachable() async throws {
        struct Failure: Error {}
        let content = LMStudioDashboardPaneContent()
        content.clock = TestClock()
        content.cliExecutableURLProvider = { URL(fileURLWithPath: "/nonexistent/lms") }
        content.fetchModels = { throw Failure() }
        let modelsPollApplied = EventCounter(content.modelsPollAppliedEventsForTesting())

        content.setUp(visible: false)
        guard await modelsPollApplied.awaitCount(1) else {
            Issue.record("first models-poll attempt never applied")
            content.tearDown()
            return
        }
        #expect(content.connectionState == .connected, "one failure must not yet trip the two-strike rule")

        content.refreshNow()
        guard await modelsPollApplied.awaitCount(2) else {
            Issue.record("second models-poll attempt never applied")
            content.tearDown()
            return
        }
        #expect(content.connectionState == .unreachable, "a second consecutive failure must trip the two-strike rule")

        content.tearDown()
    }

    /// Once reachable, a `.notInstalled` machine should never silently
    /// read as `.unreachable` (CLI-missing takes priority — a real LM
    /// Studio it can't drive a live feed for either way). Advances the
    /// injected clock through several poll ticks — including one driven by
    /// `startModelsPollTask`'s own interval, not just its first, immediate
    /// call — to prove the invariant holds across repeated failures, not
    /// only at the very first attempt.
    @Test func connectionStateNeverConflatesNotInstalledWithUnreachable() async throws {
        struct Failure: Error {}
        let content = LMStudioDashboardPaneContent()
        let clock = TestClock()
        content.clock = clock
        content.cliExecutableURLProvider = { nil }
        content.fetchModels = { throw Failure() }
        let modelsPollApplied = EventCounter(content.modelsPollAppliedEventsForTesting())

        // `setUp(visible: false)` runs only `setUp`'s own one-shot poll —
        // `startActiveWork()` (and so `startModelsPollTask`'s loop) never
        // runs while hidden — so this is one deterministic attempt with no
        // ambiguity about which Task produced it.
        content.setUp(visible: false)
        guard await modelsPollApplied.awaitCount(1) else {
            Issue.record("first models-poll attempt never applied")
            content.tearDown()
            return
        }
        // `refreshNow()` drives a second, equally deterministic attempt,
        // crossing the two-strike threshold — `httpReachable` is false
        // before either of `setVisible(true)`'s two Tasks below ever runs.
        content.refreshNow()
        guard await modelsPollApplied.awaitCount(2) else {
            Issue.record("second models-poll attempt never applied")
            content.tearDown()
            return
        }
        #expect(content.connectionState == .notInstalled)

        // `setVisible(true)` starts `startModelsPollTask`'s loop *and*
        // fires its own one-shot poll. With `httpReachable` already false
        // from the two attempts above, there is no longer any race about
        // which of these two new Tasks reads it first when picking a sleep
        // interval — the value they'd read is already settled, whichever
        // completes first. Both still count toward `modelsPollApplied`.
        content.setVisible(true)
        guard await modelsPollApplied.awaitCount(4) else {
            Issue.record("setVisible(true)'s one-shot and the loop's first iteration did not both apply")
            content.tearDown()
            return
        }

        guard await clock.waitForSleepers(1) else {
            Issue.record("models poll loop never registered its interval sleep")
            content.tearDown()
            return
        }
        // With `httpReachable` already false, the loop's own sleep must use
        // `reachabilityPollInterval`, not `modelsPollInterval` — a mutation
        // that kept polling at `modelsPollInterval`, ignoring the backoff,
        // would fire here.
        let firedAtModelsInterval = await clock.advance(by: content.modelsPollInterval)
        #expect(firedAtModelsInterval == 0, "the backed-off sleeper must not be due yet at modelsPollInterval")
        let remainder = content.reachabilityPollInterval - content.modelsPollInterval
        let firedAtReachabilityInterval = await clock.advance(by: remainder)
        #expect(firedAtReachabilityInterval == 1)
        // Cumulative: the four attempts already counted above, plus this
        // interval-driven one.
        guard await modelsPollApplied.awaitCount(5) else {
            Issue.record("models poll loop never applied its interval-driven attempt")
            content.tearDown()
            return
        }

        #expect(content.connectionState == .notInstalled)

        content.tearDown()
    }

    // MARK: - Reconnect backoff

    @Test func modelStreamExitingUnexpectedlyReportsReconnecting() async throws {
        let content = LMStudioDashboardPaneContent()
        let clock = TestClock()
        content.clock = clock
        content.cliExecutableURLProvider = { URL(fileURLWithPath: "/fake/lms") }
        content.fetchModels = { self.emptyModelsResponse() }
        content.makeRuntimeStreamProcess = makeSleepForeverProcess
        content.makeModelStreamProcess = { _ in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "exit 0"]
            return process
        }
        // The clock is never advanced, so the scheduled respawn's
        // `clock.sleep(for: respawnDelay)` never fires mid-assertion — no
        // 30s real-time dodge needed.
        content.respawnDelay = .seconds(2)
        let terminationHandled = EventCounter(content.streamTerminationHandledEventsForTesting())

        content.setUp(visible: true)
        guard await terminationHandled.awaitCount(1) else {
            Issue.record("model-stream's unexpected exit was never handled")
            content.tearDown()
            await content.awaitPendingTeardownReapsForTesting()
            _ = await clock.advance(by: content.respawnDelay)
            return
        }

        #expect(content.connectionState == .reconnecting)

        content.tearDown()
        // Real runtime-stream subprocess — await the reap so it doesn't
        // outlive this test (#0354).
        await content.awaitPendingTeardownReapsForTesting()
        // The unexpected exit above scheduled a respawn `clock.sleep(for:
        // respawnDelay)` that this test deliberately never advanced past
        // (so `.reconnecting` stayed observable) — release it now that
        // `tearDown()` has run (`scheduleRespawn`'s own guard checks
        // `controller.phase == .active`, now false, so releasing it here
        // just lets that `Task` complete as a no-op instead of leaving it
        // parked on `clock` for the rest of the process's life).
        _ = await clock.advance(by: content.respawnDelay)
    }

    /// `modelStreamExitingUnexpectedlyReportsReconnecting` never advances
    /// the clock at all, so it can't distinguish "waits the full
    /// `respawnDelay`" from a mutation that respawns early (e.g. after only
    /// half the delay). This test does: advances to just under the full
    /// delay and confirms nothing has respawned yet, then advances the
    /// remainder and confirms it has.
    @Test func respawnWaitsTheFullRespawnDelayNotJustPartOfIt() async throws {
        final class SpawnCount {
            var value = 0
        }
        let spawnCount = SpawnCount()

        let content = LMStudioDashboardPaneContent()
        let clock = TestClock()
        content.clock = clock
        content.cliExecutableURLProvider = { URL(fileURLWithPath: "/fake/lms") }
        content.fetchModels = { self.emptyModelsResponse() }
        // `setUp(visible: true)` also starts the models-poll and `lms ps`
        // poll loops on this same shared clock — set their intervals far
        // beyond `respawnDelay` so neither sleeper interferes with the
        // precise advances below.
        content.modelsPollInterval = .seconds(1000)
        content.psPollInterval = .seconds(1000)
        content.respawnDelay = .seconds(10)
        content.makeRuntimeStreamProcess = makeSleepForeverProcess
        content.makeModelStreamProcess = { _ in
            spawnCount.value += 1
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            if spawnCount.value == 1 {
                process.arguments = ["-c", "exit 0"]
            } else {
                // Prints a real, parseable line — `lineApplied` below is
                // the completion signal for "the respawn actually ran and
                // its process is live," since firing the clock's sleeper
                // only resumes the respawn `Task`'s continuation; it
                // doesn't wait for that `Task` to actually finish calling
                // `spawnModelStream`.
                let normalLine = self.predictionInputLine(modelIdentifier: "after-full-delay", timestamp: self.nowMillis())
                process.arguments = ["-c", "printf '%s\\n' '\(normalLine)'; exec sleep 60"]
            }
            return process
        }
        let terminationHandled = EventCounter(content.streamTerminationHandledEventsForTesting())
        let lineApplied = EventCounter(content.lineAppliedEventsForTesting())

        content.setUp(visible: true)
        guard await terminationHandled.awaitCount(1) else {
            Issue.record("model-stream's unexpected exit was never handled")
            content.tearDown()
            await content.awaitPendingTeardownReapsForTesting()
            _ = await clock.advance(by: content.respawnDelay)
            return
        }
        // Models loop, ps loop, and now the respawn delay all share this
        // clock — wait for the true total so this actually synchronizes on
        // the respawn's own sleep, not just whichever sleeper registered
        // first (see `bufferResetsOnRespawnSoPendingDropDoesNotSwallowNewProcessFirstLine`'s
        // identical reasoning).
        guard await clock.waitForSleepers(3) else {
            Issue.record("expected the models loop, the ps loop, and the respawn delay all parked on the clock")
            content.tearDown()
            await content.awaitPendingTeardownReapsForTesting()
            _ = await clock.advance(by: content.respawnDelay)
            return
        }

        let firedJustUnder = await clock.advance(by: content.respawnDelay - .milliseconds(1))
        #expect(firedJustUnder == 0, "the respawn must not fire before the full respawnDelay elapses")
        #expect(spawnCount.value == 1)

        let firedAtFullDelay = await clock.advance(by: .milliseconds(1))
        #expect(firedAtFullDelay == 1)
        guard await lineApplied.awaitCount(1) else {
            Issue.record("respawned process's line was never applied")
            content.tearDown()
            await content.awaitPendingTeardownReapsForTesting()
            return
        }
        #expect(spawnCount.value == 2)
        #expect(content.inFlight.first?.modelIdentifier == "after-full-delay")

        content.tearDown()
        await content.awaitPendingTeardownReapsForTesting()
    }

    // MARK: - Live stream parsing (real pipe, fake `lms`)

    @Test func parsesAPredictionInputThenOutputIntoRecentCompletions() async throws {
        let content = LMStudioDashboardPaneContent()
        content.clock = TestClock()
        content.cliExecutableURLProvider = { URL(fileURLWithPath: "/fake/lms") }
        content.fetchModels = { self.emptyModelsResponse() }
        content.makeRuntimeStreamProcess = makeSleepForeverProcess
        content.makeModelStreamProcess = { _ in
            let inputLine = self.predictionInputLine(modelIdentifier: "m", timestamp: self.nowMillis())
            let outputLine = self.predictionOutputLine(modelIdentifier: "m", timestamp: self.nowMillis())
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "printf '%s\\n' 'Streaming logs from LM Studio' '' '\(inputLine)' '\(outputLine)'; exec sleep 60"]
            return process
        }

        let lineApplied = EventCounter(content.lineAppliedEventsForTesting())
        content.setUp(visible: true)
        guard await lineApplied.awaitCount(2) else {
            Issue.record("did not observe both the input and output lines being applied")
            content.tearDown()
            await content.awaitPendingTeardownReapsForTesting()
            return
        }

        #expect(content.inFlight.isEmpty)
        #expect(content.recentCompletions.count == 1)
        #expect(content.recentCompletions.first?.modelIdentifier == "m")
        #expect(content.recentCompletions.first?.stats?.stopReason == "eosFound")

        content.tearDown()
        // Real subprocesses — await the reap so neither outlives this test
        // (#0354).
        await content.awaitPendingTeardownReapsForTesting()
    }

    @Test func runtimeStreamKeepsEveryLineButWarningsAndErrorsFiltersThem() async throws {
        let content = LMStudioDashboardPaneContent()
        content.clock = TestClock()
        content.cliExecutableURLProvider = { URL(fileURLWithPath: "/fake/lms") }
        content.fetchModels = { self.emptyModelsResponse() }
        content.makeModelStreamProcess = makeSleepForeverProcess
        let lines = [
            #"{"timestamp":1786253679000,"data":{"type":"runtime.log","level":"debug","message":"[kit][INFO]: loaded","engineName":"mlx"}}"#,
            #"{"timestamp":1786253680000,"data":{"type":"runtime.log","level":"debug","message":"[kit][ERROR]: failed","engineName":"mlx"}}"#,
            #"{"timestamp":1786253681000,"data":{"type":"runtime.log","level":"warn","message":"slow","engineName":"mlx"}}"#,
        ]
        content.makeRuntimeStreamProcess = { _ in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "printf '%s\\n' '\(lines[0])' '\(lines[1])' '\(lines[2])'; exec sleep 60"]
            return process
        }

        let lineApplied = EventCounter(content.lineAppliedEventsForTesting())
        content.setUp(visible: true)
        guard await lineApplied.awaitCount(3) else {
            Issue.record("did not observe the runtime lines being applied")
            content.tearDown()
            await content.awaitPendingTeardownReapsForTesting()
            return
        }

        #expect(content.engineErrors.count == 3)
        #expect(content.warningsAndErrors.count == 2)
        #expect(content.warningsAndErrors.map(\.message) == ["slow", "[kit][ERROR]: failed"])

        content.tearDown()
        await content.awaitPendingTeardownReapsForTesting()
    }

    @Test func unmatchedInputStaysInFlight() async throws {
        let content = LMStudioDashboardPaneContent()
        content.clock = TestClock()
        content.cliExecutableURLProvider = { URL(fileURLWithPath: "/fake/lms") }
        content.fetchModels = { self.emptyModelsResponse() }
        content.makeRuntimeStreamProcess = makeSleepForeverProcess
        content.makeModelStreamProcess = { _ in
            let inputLine = self.predictionInputLine(modelIdentifier: "m", timestamp: self.nowMillis())
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "printf '%s\\n' '\(inputLine)'; exec sleep 60"]
            return process
        }
        let lineApplied = EventCounter(content.lineAppliedEventsForTesting())

        content.setUp(visible: true)
        guard await lineApplied.awaitCount(1) else {
            Issue.record("input line was never applied")
            content.tearDown()
            await content.awaitPendingTeardownReapsForTesting()
            return
        }

        #expect(content.inFlight.count == 1)
        #expect(content.inFlight.first?.modelIdentifier == "m")

        content.tearDown()
        // Real subprocesses — await the reap so neither outlives this test
        // (#0354).
        await content.awaitPendingTeardownReapsForTesting()
    }

    // MARK: - `lms ps` cross-check gating (pure function)

    @Test func shouldEvictOnlyWhenIdleMatchingAndStartedBeforeSample() {
        let sampledAt = Date()
        let before = sampledAt.addingTimeInterval(-1)
        let after = sampledAt.addingTimeInterval(1)
        let idleEntry = LMStudioPsEntry(identifier: "m", modelKey: nil, status: "idle", deviceIdentifier: nil, ttlMs: nil)
        let generatingEntry = LMStudioPsEntry(identifier: "m", modelKey: nil, status: "generating", deviceIdentifier: nil, ttlMs: nil)

        #expect(LMStudioDashboardPaneContent.shouldEvictInFlight(
            candidateModelIdentifier: "m", candidateStartedAt: before, psEntry: idleEntry, sampledAt: sampledAt
        ) == true)

        // The phase-2 obligation this fixes: a prediction that started
        // *after* the `lms ps` sample was taken must not be evicted, even
        // though the sample itself reports idle — it can't have observed
        // this request yet.
        #expect(LMStudioDashboardPaneContent.shouldEvictInFlight(
            candidateModelIdentifier: "m", candidateStartedAt: after, psEntry: idleEntry, sampledAt: sampledAt
        ) == false)

        #expect(LMStudioDashboardPaneContent.shouldEvictInFlight(
            candidateModelIdentifier: "m", candidateStartedAt: before, psEntry: generatingEntry, sampledAt: sampledAt
        ) == false)

        #expect(LMStudioDashboardPaneContent.shouldEvictInFlight(
            candidateModelIdentifier: "other", candidateStartedAt: before, psEntry: idleEntry, sampledAt: sampledAt
        ) == false)
    }

    @Test func staleInFlightIsEvictedOnceThePsPollCrossChecksIt() async throws {
        // A mutable box the injected `fetchPsEntries` reads on every call —
        // starts reporting "generating" so the ps cross-check cannot evict
        // the in-flight entry the instant it's created (the race this test
        // must avoid: with `lms ps` always idle from the start, a poll
        // that happens to land after the entry's creation but before this
        // test's own first assertion would evict it non-deterministically).
        // Only once the test has confirmed the entry exists does it flip
        // to "idle" and wait for the next tick to observe the eviction.
        final class PsStatusBox {
            var status = "generating"
        }
        let box = PsStatusBox()

        let content = LMStudioDashboardPaneContent()
        // Seeded to the real "now," not `TestClock`'s default 1970 epoch:
        // `recordInFlight`'s `startedAt` comes from the log line's own
        // (real, wall-clock) `timestamp` field, and `pollPsOnce`'s
        // `sampledAt` comes from this clock — the two must be comparable.
        // The poll interval below is a large *virtual* step (no real time
        // is actually spent waiting on it), generous enough to safely clear
        // whatever real, wall-clock delay elapses between constructing this
        // clock and the model-stream subprocess actually emitting its line.
        let clock = TestClock(now: Date())
        content.clock = clock
        content.cliExecutableURLProvider = { URL(fileURLWithPath: "/fake/lms") }
        content.fetchModels = { self.emptyModelsResponse() }
        content.psPollInterval = .seconds(10)
        // `setUp(visible: true)` also starts the models-poll loop on this
        // same shared clock — set its interval far beyond `psPollInterval`
        // so its sleeper never fires when this test advances by
        // `psPollInterval` below; it still counts toward `waitForSleepers`'
        // total, just never toward `advance`'s fired count.
        content.modelsPollInterval = .seconds(1000)
        content.fetchPsEntries = { _ in
            [LMStudioPsEntry(identifier: "m", modelKey: nil, status: box.status, deviceIdentifier: nil, ttlMs: nil)]
        }
        content.makeRuntimeStreamProcess = makeSleepForeverProcess
        content.makeModelStreamProcess = { _ in
            let inputLine = self.predictionInputLine(modelIdentifier: "m", timestamp: self.nowMillis())
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "printf '%s\\n' '\(inputLine)'; exec sleep 60"]
            return process
        }
        let lineApplied = EventCounter(content.lineAppliedEventsForTesting())
        let psPollApplied = EventCounter(content.psPollAppliedEventsForTesting())

        content.setUp(visible: true)
        // `startPsPollTask`'s loop runs one poll immediately, before its
        // first sleep. `EventCounter.awaitCount` is cumulative — it counts
        // every occurrence observed so far, not "the next one since the
        // last call" — so `awaitCount(1)` here just establishes a floor
        // ("at least the immediate 'generating' attempt has landed");
        // `awaitCount(2)` below is what actually waits for a *second*,
        // distinct occurrence (the interval-driven "idle" one).
        guard await psPollApplied.awaitCount(1) else {
            Issue.record("ps poll's initial attempt was never applied")
            content.tearDown()
            await content.awaitPendingTeardownReapsForTesting()
            return
        }
        guard await lineApplied.awaitCount(1) else {
            Issue.record("input line was never applied")
            content.tearDown()
            await content.awaitPendingTeardownReapsForTesting()
            return
        }
        #expect(content.inFlight.count == 1)

        box.status = "idle"
        // Both the models loop (interval 1000s, never fired in this test)
        // and the ps loop (interval `psPollInterval`) share this one clock,
        // so `waitForSleepers(1)` would already be satisfied by whichever
        // registered first — vacuously, regardless of whether the ps loop's
        // *own* sleep has registered yet. Waiting for the true total (both
        // loops parked) is what actually synchronizes on the ps loop's
        // sleep specifically.
        guard await clock.waitForSleepers(2) else {
            Issue.record("expected both the models loop and the ps loop to be parked on the clock")
            content.tearDown()
            await content.awaitPendingTeardownReapsForTesting()
            return
        }
        let fired = await clock.advance(by: content.psPollInterval)
        // Exactly the ps loop's sleeper — the models loop's (1000s away)
        // must not also fire here.
        #expect(fired == 1)
        // Cumulative count: the first (immediate, "generating") attempt was
        // already counted above, so this is the interval-driven ("idle")
        // one.
        guard await psPollApplied.awaitCount(2) else {
            Issue.record("ps poll never applied its interval-driven attempt")
            content.tearDown()
            await content.awaitPendingTeardownReapsForTesting()
            return
        }
        #expect(content.inFlight.isEmpty)

        content.tearDown()
        // Real subprocesses — await the reap so neither outlives this test
        // (#0354).
        await content.awaitPendingTeardownReapsForTesting()
    }

    // MARK: - Subprocess teardown (review round 1, B3; #0354)

    /// The contract `issues/0313.md` binds — "log evidence, a counter, a
    /// footprint delta — not an assertion" — is not satisfied by checking
    /// `lifecyclePhase == .tornDown` alone: that only proves the state
    /// machine transitioned, not that the real subprocess died. This test
    /// captures the actual `Process` objects the injected factories hand
    /// out and asserts `isRunning == false` on them after `tearDown()` —
    /// commenting out `terminateModelStream`'s/`terminateRuntimeStream`'s
    /// `process.terminate()` call makes this test fail, which
    /// `lifecyclePhase`-only assertions did not. `tearDown()` no longer
    /// blocks the main actor until the subprocess exits (#0354), so this
    /// awaits the scheduled reap task before checking `isRunning` rather
    /// than asserting immediately.
    @Test func tearDownActuallyTerminatesBothSubprocesses() async throws {
        final class ProcessBox {
            var model: Process?
            var runtime: Process?
        }
        let box = ProcessBox()

        let content = LMStudioDashboardPaneContent()
        content.clock = TestClock()
        content.cliExecutableURLProvider = { URL(fileURLWithPath: "/fake/lms") }
        content.fetchModels = { self.emptyModelsResponse() }
        content.makeModelStreamProcess = { url in
            let process = self.makeSleepForeverProcess(url)
            box.model = process
            return process
        }
        content.makeRuntimeStreamProcess = { url in
            let process = self.makeSleepForeverProcess(url)
            box.runtime = process
            return process
        }

        // `startActiveWork()` (called synchronously from `setUp(visible:
        // true)`) calls `spawnModelStream`/`spawnRuntimeStream` synchronously
        // too, and `Process.run()` itself returns only once the child image
        // is live (`posix_spawn` — verified in
        // `docs/async-test-seams.md` §5.1) — so both subprocesses are
        // already running by the time `setUp` returns; no wait needed.
        content.setUp(visible: true)

        let model = try #require(box.model)
        let runtime = try #require(box.runtime)
        #expect(model.isRunning)
        #expect(runtime.isRunning)

        content.tearDown()
        await content.awaitPendingTeardownReapsForTesting()

        #expect(model.isRunning == false)
        #expect(runtime.isRunning == false)
    }

    /// #0354's core claim: `tearDown()` must return promptly on the main
    /// actor even when both subprocesses ignore `SIGTERM` — the previous
    /// implementation blocked the calling thread (the main actor, since
    /// this class is `@MainActor`) in a `Thread.sleep` poll for up to
    /// `teardownWaitBound` per stream. `teardownWaitBound` is lowered here
    /// only to keep the eventual SIGKILL escalation fast once the gate
    /// opens.
    ///
    /// #0428's `TeardownReapGate` proves "returns without blocking"
    /// structurally instead of by timing the call
    /// (`docs/async-test-seams.md` §3): held closed, `tearDown()` returning
    /// while both children are still alive and a waiter is confirmed parked
    /// on the gate is airtight regardless of machine speed.
    ///
    /// #0424: waits on `LMStudioSIGTERMIgnoringFixture`'s ready-file
    /// handshake, not a fixed sleep, before sending `SIGTERM` — a fixed
    /// sleep can't prove `sh` has parsed `trap '' TERM` yet, so under host
    /// load `tearDown()`'s `SIGTERM` could kill the child on the default
    /// disposition before the trap installs, and this test would pass
    /// without ever reaching the `SIGKILL` escalation it means to prove.
    @Test func tearDownReturnsPromptlyEvenWhenBothChildrenIgnoreSIGTERM() async throws {
        final class ProcessBox {
            var model: Process?
            var runtime: Process?
        }
        let box = ProcessBox()

        let (readyDirectory, cleanupReadyDirectory) = try LMStudioSIGTERMIgnoringFixture.makeReadyDirectory(
            callerTag: "returns-promptly"
        )
        defer { cleanupReadyDirectory() }
        let modelReadyURL = readyDirectory.appendingPathComponent("model-ready")
        let runtimeReadyURL = readyDirectory.appendingPathComponent("runtime-ready")

        let content = LMStudioDashboardPaneContent()
        content.clock = TestClock()
        let gate = TestTeardownReapGate()
        content.reapGate = gate
        content.cliExecutableURLProvider = { URL(fileURLWithPath: "/fake/lms") }
        content.fetchModels = { self.emptyModelsResponse() }
        content.teardownWaitBound = 0.2
        content.makeModelStreamProcess = { _ in
            let process = LMStudioSIGTERMIgnoringFixture.makeProcess(readyFileURL: modelReadyURL)
            box.model = process
            return process
        }
        content.makeRuntimeStreamProcess = { _ in
            let process = LMStudioSIGTERMIgnoringFixture.makeProcess(readyFileURL: runtimeReadyURL)
            box.runtime = process
            return process
        }

        // A safety net for *any* exit from here on — a failed readiness
        // guard below, a throwing `#require`, or simply falling off the end
        // — so a real child is never left alive with the gate stuck closed.
        // `defer` bodies are synchronous, and both `gate.open()` and
        // `killAndReap` are: opening an already-open gate or killing an
        // already-dead process is a harmless no-op, so this runs safely
        // even after the test's own explicit `gate.open()` below already
        // did the real cleanup.
        defer {
            gate.open()
            killAndReap(box.model)
            killAndReap(box.runtime)
        }

        content.setUp(visible: true)

        guard await LMStudioSIGTERMIgnoringFixture.waitForReadyFile(modelReadyURL) else {
            Issue.record("model-stream never installed its SIGTERM trap")
            return
        }
        guard await LMStudioSIGTERMIgnoringFixture.waitForReadyFile(runtimeReadyURL) else {
            Issue.record("runtime-stream never installed its SIGTERM trap")
            return
        }

        let model = try #require(box.model)
        let runtime = try #require(box.runtime)
        #expect(model.isRunning)
        #expect(runtime.isRunning)

        content.tearDown()

        // The state machine transitions synchronously — that guarantee is
        // unchanged by #0354's fix.
        #expect(content.lifecyclePhase == .tornDown)

        // A closed gate only proves something once a caller is actually
        // parked on it — one waiter per stream (model, runtime).
        guard await gate.waitForParkedWaiter(2) else {
            Issue.record("gate never saw both reap tasks park")
            gate.open()
            await content.awaitPendingTeardownReapsForTesting()
            return
        }
        // `tearDown()` already returned above, the gate is still closed,
        // and both children are still alive — proving the wait really was
        // moved off the main actor, not just made faster.
        #expect(model.isRunning)
        #expect(runtime.isRunning)

        gate.open()
        await content.awaitPendingTeardownReapsForTesting()

        // Eventually killed/reaped via the SIGKILL escalation, even though
        // neither child ever cooperated with SIGTERM.
        #expect(model.isRunning == false)
        #expect(runtime.isRunning == false)
    }

    /// Same proof for the `setVisible(false)` (hide) path, which tears
    /// down subprocesses without the bounded wait `tearDown()` uses — this
    /// checks that `SIGTERM` alone (no explicit poll) is still enough to
    /// kill a normal `/bin/sh -c "exec sleep 60"` promptly.
    @Test func hidingActuallyTerminatesBothSubprocesses() async throws {
        final class ProcessBox {
            var model: Process?
            var runtime: Process?
        }
        let box = ProcessBox()

        let content = LMStudioDashboardPaneContent()
        content.clock = TestClock()
        content.cliExecutableURLProvider = { URL(fileURLWithPath: "/fake/lms") }
        content.fetchModels = { self.emptyModelsResponse() }
        content.makeModelStreamProcess = { url in
            let process = self.makeSleepForeverProcess(url)
            box.model = process
            return process
        }
        content.makeRuntimeStreamProcess = { url in
            let process = self.makeSleepForeverProcess(url)
            box.runtime = process
            return process
        }

        let terminationHandled = EventCounter(content.streamTerminationHandledEventsForTesting())

        // Spawn is synchronous with `setUp(visible: true)` (see
        // `tearDownActuallyTerminatesBothSubprocesses`'s comment).
        content.setUp(visible: true)
        #expect(box.model?.isRunning == true)
        #expect(box.runtime?.isRunning == true)

        content.setVisible(false)
        // No bounded wait on this path — await both terminations actually
        // being handled instead of guessing how long the signal takes to
        // land.
        guard await terminationHandled.awaitCount(2) else {
            Issue.record("did not observe both streams' terminations being handled")
            // `setVisible(false)` already nils out `modelStreamProcess`/
            // `runtimeStreamProcess` regardless of whether SIGTERM actually
            // landed, and the hide path never schedules a bounded reap
            // (`boundedWait: false`) — so `content.tearDown()` has nothing
            // left to terminate, and `awaitPendingTeardownReapsForTesting()`
            // awaits an empty list. Under a mutation that drops the
            // `terminate()` call, that combination left a real `sleep 60`
            // orphaned with no cleanup path at all. Kill and reap
            // `box.model`/`box.runtime` directly instead of relying on
            // `content` to do it.
            content.tearDown()
            killAndReap(box.model)
            killAndReap(box.runtime)
            return
        }

        #expect(box.model?.isRunning == false)
        #expect(box.runtime?.isRunning == false)

        content.tearDown()
    }

    // MARK: - #0355: NDJSONLineBuffer (pure, deterministic)

    @Test func multipleCompleteLinesInOneChunkAreAllExtractedInOrder() {
        var buffer = NDJSONLineBuffer()
        let chunk = Data("one\ntwo\nthree\n".utf8)

        let result = buffer.append(chunk, maxLineBytes: 1024)

        #expect(result.lines == ["one", "two", "three"])
        #expect(result.droppedLineCount == 0)
        #expect(result.droppedByteCount == 0)
    }

    @Test func lineSplitAcrossTwoAppendsIsReassembled() {
        var buffer = NDJSONLineBuffer()

        let first = buffer.append(Data("ab".utf8), maxLineBytes: 1024)
        #expect(first.lines.isEmpty)

        let second = buffer.append(Data("c\ndef\n".utf8), maxLineBytes: 1024)
        #expect(second.lines == ["abc", "def"])
    }

    @Test func completedLineOverCapIsDroppedAndNextLineIsUnaffected() {
        var buffer = NDJSONLineBuffer()
        let oversized = String(repeating: "x", count: 20)
        let chunk = Data("\(oversized)\nshort\n".utf8)

        let result = buffer.append(chunk, maxLineBytes: 10)

        #expect(result.lines == ["short"])
        #expect(result.beganDroppingOversizedLine == false)
        #expect(result.droppedLineCount == 1)
        #expect(result.droppedByteCount == 20)
    }

    /// The vector issue #0355 names explicitly: a stream that withholds
    /// `\n` entirely must not let the buffer grow without bound, and must
    /// not re-signal on every subsequent no-newline chunk — only once,
    /// when the drop begins. Feeds the cap, then five
    /// more no-newline chunks, then the terminator, checking at every step
    /// that `beganDroppingOversizedLine` fires exactly once and that
    /// nothing is reported as a *finished* drop until the `\n` arrives —
    /// at which point the report carries the full cumulative size, proving
    /// the bytes were tracked (not lost) while being silently discarded.
    @Test func neverTerminatedLineSignalsOnceThenDropsSilentlyUntilItsNewlineArrives() {
        var buffer = NDJSONLineBuffer()
        let maxLineBytes = 100
        let chunk = Data(String(repeating: "y", count: 40).utf8)

        let first = buffer.append(chunk, maxLineBytes: maxLineBytes)
        #expect(first.lines.isEmpty)
        #expect(first.beganDroppingOversizedLine == false)
        #expect(first.droppedLineByteCounts.isEmpty)

        // 80 bytes pending, still under the 100-byte cap.
        let second = buffer.append(chunk, maxLineBytes: maxLineBytes)
        #expect(second.beganDroppingOversizedLine == false)
        #expect(second.droppedLineByteCounts.isEmpty)

        // 120 bytes pending — now over cap: signals exactly once that a
        // drop has begun. Nothing is reported as *finished* yet, since the
        // line hasn't reached its terminator.
        let third = buffer.append(chunk, maxLineBytes: maxLineBytes)
        #expect(third.lines.isEmpty)
        #expect(third.beganDroppingOversizedLine == true)
        #expect(third.droppedLineByteCounts.isEmpty)

        // Already in dropping mode: five more chunks arrive, none of them
        // signal again — a regression here would re-signal (or the caller
        // would re-log) on every subsequent no-newline chunk instead.
        for _ in 0..<5 {
            let result = buffer.append(chunk, maxLineBytes: maxLineBytes)
            #expect(result.lines.isEmpty)
            #expect(result.beganDroppingOversizedLine == false)
            #expect(result.droppedLineByteCounts.isEmpty)
        }

        // The terminator finally arrives: one finished-drop entry for the
        // *entire* run (120 + 5×40 pending bytes, plus the newline byte
        // itself), not just this last chunk's size.
        let terminator = buffer.append(Data("\n".utf8), maxLineBytes: maxLineBytes)
        #expect(terminator.beganDroppingOversizedLine == false)
        #expect(terminator.droppedLineByteCounts == [120 + 5 * chunk.count + 1])
    }

    /// Recovery: once the terminating `\n` for a never-terminated run
    /// finally arrives, the buffer resynchronizes and correctly parses
    /// whatever comes after it — it doesn't stay wedged in dropping mode.
    @Test func neverTerminatedLineResynchronizesAtNextNewlineAndRecovers() {
        var buffer = NDJSONLineBuffer()
        let maxLineBytes = 50
        let garbage = Data(String(repeating: "z", count: 60).utf8)

        let overflow = buffer.append(garbage, maxLineBytes: maxLineBytes)
        #expect(overflow.lines.isEmpty)
        #expect(overflow.beganDroppingOversizedLine == true)
        #expect(overflow.droppedLineByteCounts.isEmpty)

        // The lone newline that finally ends the garbage run — reports the
        // full 60 garbage bytes plus the newline itself, as one entry.
        let terminator = buffer.append(Data("\n".utf8), maxLineBytes: maxLineBytes)
        #expect(terminator.lines.isEmpty)
        #expect(terminator.beganDroppingOversizedLine == false)
        #expect(terminator.droppedLineByteCounts == [61])

        // Normal parsing resumes immediately after.
        let recovered = buffer.append(Data("recovered\n".utf8), maxLineBytes: maxLineBytes)
        #expect(recovered.lines == ["recovered"])
        #expect(recovered.droppedLineCount == 0)
    }

    // MARK: - #0355: inFlight hard cap (through the full pipeline)

    /// Exceeds `inFlightCap` with unmatched `input` events (no `output` is
    /// ever sent, so nothing pairs off and every entry stays in-flight) and
    /// confirms the oldest entries — not the newest — are the ones evicted.
    @Test func inFlightExceedingCapEvictsOldestEntriesFirst() async throws {
        let cap = LMStudioDashboardPaneContent.inFlightCap
        let totalSent = cap + 10

        let content = LMStudioDashboardPaneContent()
        content.clock = TestClock()
        content.cliExecutableURLProvider = { URL(fileURLWithPath: "/fake/lms") }
        content.fetchModels = { self.emptyModelsResponse() }
        // Long enough that the 5-minute-default staleness sweep can't be
        // the thing thinning the list — this test is about the hard cap.
        content.staleInFlightWindow = 24 * 60 * 60
        content.makeRuntimeStreamProcess = makeSleepForeverProcess
        content.makeModelStreamProcess = { _ in
            let baseTimestamp = self.nowMillis()
            let lines = (0..<totalSent).map { index in
                self.predictionInputLine(modelIdentifier: "m-\(index)", timestamp: baseTimestamp + Int64(index))
            }
            let script = lines.map { "printf '%s\\n' '\($0)'" }.joined(separator: "; ")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "\(script); exec sleep 60"]
            return process
        }

        let lineApplied = EventCounter(content.lineAppliedEventsForTesting())
        content.setUp(visible: true)
        // Await exactly `totalSent` applied-line events rather than
        // inspecting `inFlight` mid-delivery — the count already reads
        // `cap` partway through delivery (every insert past the cap evicts
        // one), so counting `inFlight` alone can't tell "all lines arrived"
        // from "the cap engaged early." Each event fires only once its
        // line has already been applied (`recordInFlight`/eviction
        // included), so having observed `totalSent` of them is itself the
        // completion signal.
        guard await lineApplied.awaitCount(totalSent) else {
            Issue.record("did not observe all \(totalSent) lines being applied")
            content.tearDown()
            await content.awaitPendingTeardownReapsForTesting()
            return
        }

        #expect(content.inFlight.count == cap)
        let retainedIdentifiers = Set(content.inFlight.map(\.modelIdentifier))
        // The oldest 10 (m-0..<m-9) must be gone; the newest `cap` must remain.
        for index in 0..<10 {
            #expect(!retainedIdentifiers.contains("m-\(index)"))
        }
        for index in (totalSent - cap)..<totalSent {
            #expect(retainedIdentifiers.contains("m-\(index)"))
        }

        content.tearDown()
        await content.awaitPendingTeardownReapsForTesting()
    }

    // MARK: - #0355: oversized line through the full pipeline

    /// A single NDJSON line far larger than `streamLineByteCap` (an
    /// adversarial or runaway `-s model` line) must not wedge the parser —
    /// the next, normal-sized line must still be parsed correctly.
    @Test func oversizedLineThroughRealPipeIsDroppedAndPipelineRecovers() async throws {
        let content = LMStudioDashboardPaneContent()
        content.clock = TestClock()
        content.cliExecutableURLProvider = { URL(fileURLWithPath: "/fake/lms") }
        content.fetchModels = { self.emptyModelsResponse() }
        content.makeRuntimeStreamProcess = makeSleepForeverProcess
        content.makeModelStreamProcess = { _ in
            // Larger than `streamLineByteCap` (256 KB) but well-formed
            // enough to parse if it weren't dropped by the cap — proves
            // the drop is size-driven, not a parse failure. The filler is
            // generated at shell-runtime (`head`/`tr`), not embedded as a
            // literal `Process.arguments` entry, to stay well under the
            // OS's argument-length limit.
            let fillerByteCount = LMStudioDashboardPaneContent.streamLineByteCap + 4096
            let prefix = #"{"timestamp":\#(self.nowMillis()),"data":{"type":"llm.prediction.input","input":""#
            let suffix = #"","modelIdentifier":"big"}}"#
            let normalLine = self.predictionInputLine(modelIdentifier: "normal", timestamp: self.nowMillis())
            let script = """
            printf '%s' '\(prefix)'
            head -c \(fillerByteCount) /dev/zero | tr '\\0' 'p'
            printf '%s\\n' '\(suffix)'
            printf '%s\\n' '\(normalLine)'
            exec sleep 60
            """
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", script]
            return process
        }

        let lineApplied = EventCounter(content.lineAppliedEventsForTesting())
        content.setUp(visible: true)
        // The oversized line never reaches the parser as a usable line (no
        // `lineAppliedEventsForTesting` event fires for bytes
        // `NDJSONLineBuffer` drops), so exactly one event — the normal
        // line — is expected. This test pipes >256 KB of filler through
        // `head`/`tr` before that line arrives, which can take noticeably
        // longer than an isolated run under the full suite's parallel host
        // load (the isolated `swift test --filter` run finishes in well
        // under a second) — comfortably inside the shared
        // `TestBounds.hangGuard` default this call relies on.
        guard await lineApplied.awaitCount(1) else {
            Issue.record("normal-sized line was never applied")
            content.tearDown()
            await content.awaitPendingTeardownReapsForTesting()
            return
        }

        // Only the normal-sized line survived; the oversized one never
        // reached the parser as a usable line.
        #expect(content.inFlight.count == 1)
        #expect(content.inFlight.first?.modelIdentifier == "normal")

        content.tearDown()
        await content.awaitPendingTeardownReapsForTesting()
    }

    // MARK: - #0355: buffer reset on respawn

    /// If a process exits while `modelStreamBuffer` is mid-drop (a
    /// never-terminated oversized line left `isDroppingOversizedLine ==
    /// true`), that state belongs to the
    /// dead process's byte stream, not the respawned one's. Without
    /// resetting the buffer on spawn, the respawned process's first
    /// (short, valid) line would be read as "the rest of the old line"
    /// and silently dropped through its own first `\n` — this test fails
    /// with `inFlight` empty if that reset is removed.
    @Test func bufferResetsOnRespawnSoPendingDropDoesNotSwallowNewProcessFirstLine() async throws {
        final class SpawnCount {
            var value = 0
        }
        let spawnCount = SpawnCount()

        let content = LMStudioDashboardPaneContent()
        let clock = TestClock()
        content.clock = clock
        content.cliExecutableURLProvider = { URL(fileURLWithPath: "/fake/lms") }
        content.fetchModels = { self.emptyModelsResponse() }
        // `setUp(visible: true)` also starts the models-poll and `lms ps`
        // poll loops on this same shared clock — set their intervals far
        // beyond `respawnDelay` so neither sleeper ever fires when this
        // test advances by `respawnDelay` below; each still counts toward
        // `waitForSleepers`' total.
        content.modelsPollInterval = .seconds(1000)
        content.psPollInterval = .seconds(1000)
        content.makeRuntimeStreamProcess = makeSleepForeverProcess
        content.respawnDelay = .seconds(1)
        content.makeModelStreamProcess = { _ in
            spawnCount.value += 1
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            if spawnCount.value == 1 {
                // First process: emits a never-terminated line larger than
                // `streamLineByteCap`, then exits on its own (no `sleep`
                // tail) — leaves `modelStreamBuffer` mid-drop when
                // `handleModelStreamTermination` sees the unexpected exit
                // and schedules a respawn.
                let fillerByteCount = LMStudioDashboardPaneContent.streamLineByteCap + 4096
                process.arguments = ["-c", "head -c \(fillerByteCount) /dev/zero | tr '\\0' 'p'"]
            } else {
                // Respawned process: one normal, complete line.
                let normalLine = self.predictionInputLine(modelIdentifier: "after-respawn", timestamp: self.nowMillis())
                process.arguments = ["-c", "printf '%s\\n' '\(normalLine)'; exec sleep 60"]
            }
            return process
        }
        let terminationHandled = EventCounter(content.streamTerminationHandledEventsForTesting())
        let lineApplied = EventCounter(content.lineAppliedEventsForTesting())

        content.setUp(visible: true)
        // The first process's output never contains a `\n`, so it can never
        // produce a parsed line itself — its exit is only observable
        // through the termination-handled event, which is also what
        // schedules the respawn.
        guard await terminationHandled.awaitCount(1) else {
            Issue.record("first process's unexpected exit was never handled")
            content.tearDown()
            await content.awaitPendingTeardownReapsForTesting()
            // Release any respawn sleeper that did register, so its Task
            // doesn't sit parked on `clock` for the rest of the process's
            // life.
            _ = await clock.advance(by: content.respawnDelay)
            return
        }
        // Three loops share this one clock once the respawn is scheduled —
        // models, `lms ps`, and now the respawn delay — so `waitForSleepers(1)`
        // would already be satisfied by the models/ps loops alone,
        // vacuously, regardless of whether the respawn's own sleep has
        // registered yet. Waiting for the true total is what actually
        // synchronizes on the respawn specifically.
        guard await clock.waitForSleepers(3) else {
            Issue.record("expected the models loop, the ps loop, and the respawn delay all parked on the clock")
            content.tearDown()
            await content.awaitPendingTeardownReapsForTesting()
            _ = await clock.advance(by: content.respawnDelay)
            return
        }
        let fired = await clock.advance(by: content.respawnDelay)
        // Exactly the respawn's sleeper — the models/ps loops (1000s away)
        // must not also fire here.
        #expect(fired == 1)
        // Only becomes non-empty once the *respawned* process's line is
        // parsed.
        guard await lineApplied.awaitCount(1) else {
            Issue.record("respawned process's line was never applied")
            content.tearDown()
            await content.awaitPendingTeardownReapsForTesting()
            return
        }

        #expect(content.inFlight.count == 1)
        #expect(content.inFlight.first?.modelIdentifier == "after-respawn")
        #expect(spawnCount.value == 2)

        content.tearDown()
        await content.awaitPendingTeardownReapsForTesting()
    }

    // MARK: - Not-set-up safety

    @Test func freshlyConstructedContentIsNotSetUpAndDoesNothing() {
        let content = LMStudioDashboardPaneContent()
        #expect(content.lifecyclePhase == .notSetUp)
        #expect(content.loadedModels.isEmpty)
        // Hiding/showing before setUp is a legal no-op-ish rejected event,
        // not a crash.
        content.setVisible(false)
        #expect(content.lifecyclePhase == .notSetUp)
    }

    @Test func tearDownFromNotSetUpIsSafeAndIdempotent() {
        let content = LMStudioDashboardPaneContent()
        content.tearDown()
        #expect(content.lifecyclePhase == .tornDown)
        content.tearDown()
        #expect(content.lifecyclePhase == .tornDown)
    }
}

/// Counts occurrences of a production `AsyncStream<Void>` completion signal
/// and lets a test await a specific count instead of sleeping or polling —
/// the same "count + threshold waiter" shape `TestClock.waitForSleepers`/
/// `TestTeardownReapGate.waitForParkedWaiter` use (`docs/async-test-seams.md`
/// §1/§3), applied here to the "AsyncStream of events" shape (§4) instead of
/// a clock or a gate. `@unchecked Sendable` + lock, matching those two
/// types' own shape, rather than a Swift `actor`: an `actor`'s `next()` call
/// on `AsyncStream<Void>.AsyncIterator` (a plain, non-`Sendable` struct) hits
/// this toolchain's region-isolation check on the implicit hop to the
/// iterator's own non-isolated executor — the lock-guarded counter sidesteps
/// that by never handing the iterator itself across an isolation boundary; a
/// single background `Task` owns it for the counter's entire lifetime.
/// `nonisolated` on the type itself, not just its methods: this package
/// defaults to `MainActor` isolation, so without it `awaitCount`'s
/// hang-guard `DispatchWorkItem` — which resumes the continuation from a
/// background `DispatchQueue.global` queue, exactly like `TestClock`'s and
/// `TestTeardownReapGate`'s own timeout branches — would trip a
/// `dispatch_assert_queue` trap the instant a bound actually expired
/// (reproduced while mutation-checking #0429: a real regression's timeout
/// crashed the test process instead of failing it).
nonisolated private final class EventCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var waiters: [UUID: (threshold: Int, resume: () -> Void)] = [:]
    private var consumeTask: Task<Void, Never>?

    init(_ stream: AsyncStream<Void>) {
        consumeTask = Task { [weak self] in
            for await _ in stream {
                self?.increment()
            }
        }
    }

    deinit {
        consumeTask?.cancel()
    }

    private func increment() {
        lock.lock()
        count += 1
        let currentCount = count
        var satisfied: [() -> Void] = []
        for (key, waiter) in waiters where currentCount >= waiter.threshold {
            satisfied.append(waiter.resume)
            waiters.removeValue(forKey: key)
        }
        lock.unlock()
        for resume in satisfied { resume() }
    }

    private func removeWaiter(id: UUID) {
        lock.lock()
        waiters.removeValue(forKey: id)
        lock.unlock()
    }

    /// Awaits until at least `count` events have been observed in total,
    /// bounded so a genuine regression fails promptly instead of hanging
    /// the suite — `docs/async-test-seams.md` §4's rule that a bound is a
    /// failure guard only, never the mechanism a test relies on to pass.
    /// Returns `false` on expiry, removing its own waiter first (mirroring
    /// `TestClock.waitForSleepers`/`TestTeardownReapGate.waitForParkedWaiter`'s
    /// own timeout branches) so a stale entry doesn't sit in `waiters`
    /// forever being re-checked on every future `increment()`. A caller
    /// that pressed on as if the events had arrived anyway is exactly the
    /// "never continue past a failed readiness wait" hazard that doc calls
    /// out.
    func awaitCount(_ count: Int, bound: TimeInterval = TestBounds.hangGuard) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let once = ResumeOnce(continuation)
            let id = UUID()
            lock.lock()
            if self.count >= count {
                lock.unlock()
                once.resume(true)
                return
            }
            let timeoutWorkItem = DispatchWorkItem { [weak self] in
                self?.removeWaiter(id: id)
                once.resume(false)
            }
            once.setOnResumed { timeoutWorkItem.cancel() }
            waiters[id] = (threshold: count, resume: { once.resume(true) })
            lock.unlock()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + bound, execute: timeoutWorkItem)
        }
    }
}

/// A test's own failure-branch cleanup, not the normal path. Forwards to
/// `ChildProcessFixture.killAndReap(_:)` (#0441), which replaced this file's
/// own copy — kept as a thin wrapper so call sites here don't need to change.
@MainActor
private func killAndReap(_ process: Process?) {
    ChildProcessFixture.killAndReap(process)
}
