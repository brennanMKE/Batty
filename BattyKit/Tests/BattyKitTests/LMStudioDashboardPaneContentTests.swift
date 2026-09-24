// LMStudioDashboardPaneContentTests.swift

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

    private func makeSleepForeverProcess(_ url: URL) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 60"]
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

        content.setUp(visible: true)
        try await Task.sleep(for: .milliseconds(100))

        #expect(content.connectionState == .notInstalled)
        #expect(content.loadedModels.count == 1)
        #expect(content.loadedModels.first?.displayName == "M")

        content.tearDown()
    }

    // MARK: - Unreachable (two-strike rule)

    @Test func unreachableAfterTwoConsecutiveModelsPollFailures() async throws {
        struct Failure: Error {}
        let content = LMStudioDashboardPaneContent()
        content.cliExecutableURLProvider = { URL(fileURLWithPath: "/nonexistent/lms") }
        content.makeModelStreamProcess = makeSleepForeverProcess
        content.makeRuntimeStreamProcess = makeSleepForeverProcess
        content.modelsPollInterval = .milliseconds(5)
        content.fetchModels = { throw Failure() }

        content.setUp(visible: true)
        try await Task.sleep(for: .milliseconds(150))

        #expect(content.connectionState == .unreachable)

        content.tearDown()
        // Real subprocesses (`makeSleepForeverProcess`) — awaiting the reap
        // here, as every test that spawns one now must, is what keeps this
        // suite from leaking a live `sleep` process past the test's own
        // lifetime (#0354's detached reap doesn't run synchronously inside
        // `tearDown()` any more).
        await content.awaitPendingTeardownReapsForTesting()
    }

    /// Once reachable, a `.notInstalled` machine should never silently
    /// read as `.unreachable` (CLI-missing takes priority — a real LM
    /// Studio it can't drive a live feed for either way).
    @Test func connectionStateNeverConflatesNotInstalledWithUnreachable() async throws {
        struct Failure: Error {}
        let content = LMStudioDashboardPaneContent()
        content.cliExecutableURLProvider = { nil }
        content.modelsPollInterval = .milliseconds(5)
        content.fetchModels = { throw Failure() }

        content.setUp(visible: true)
        try await Task.sleep(for: .milliseconds(80))

        #expect(content.connectionState == .notInstalled)

        content.tearDown()
    }

    // MARK: - Reconnect backoff

    @Test func modelStreamExitingUnexpectedlyReportsReconnecting() async throws {
        let content = LMStudioDashboardPaneContent()
        content.cliExecutableURLProvider = { URL(fileURLWithPath: "/fake/lms") }
        content.fetchModels = { self.emptyModelsResponse() }
        content.makeRuntimeStreamProcess = makeSleepForeverProcess
        content.makeModelStreamProcess = { _ in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "exit 0"]
            return process
        }
        // Long enough that the scheduled respawn doesn't fire mid-assertion.
        content.respawnDelay = .seconds(30)

        content.setUp(visible: true)
        try await Task.sleep(for: .milliseconds(300))

        #expect(content.connectionState == .reconnecting)

        content.tearDown()
        // Real runtime-stream subprocess — await the reap so it doesn't
        // outlive this test (#0354).
        await content.awaitPendingTeardownReapsForTesting()
    }

    // MARK: - Live stream parsing (real pipe, fake `lms`)

    @Test func parsesAPredictionInputThenOutputIntoRecentCompletions() async throws {
        let content = LMStudioDashboardPaneContent()
        content.cliExecutableURLProvider = { URL(fileURLWithPath: "/fake/lms") }
        content.fetchModels = { self.emptyModelsResponse() }
        content.makeRuntimeStreamProcess = makeSleepForeverProcess
        content.makeModelStreamProcess = { _ in
            let inputLine = self.predictionInputLine(modelIdentifier: "m", timestamp: self.nowMillis())
            let outputLine = self.predictionOutputLine(modelIdentifier: "m", timestamp: self.nowMillis())
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "printf '%s\\n' 'Streaming logs from LM Studio' '' '\(inputLine)' '\(outputLine)'; sleep 60"]
            return process
        }

        content.setUp(visible: true)
        try await Task.sleep(for: .milliseconds(300))

        #expect(content.inFlight.isEmpty)
        #expect(content.recentCompletions.count == 1)
        #expect(content.recentCompletions.first?.modelIdentifier == "m")
        #expect(content.recentCompletions.first?.stats?.stopReason == "eosFound")

        content.tearDown()
        // Real subprocesses — await the reap so neither outlives this test
        // (#0354).
        await content.awaitPendingTeardownReapsForTesting()
    }

    @Test func unmatchedInputStaysInFlight() async throws {
        let content = LMStudioDashboardPaneContent()
        content.cliExecutableURLProvider = { URL(fileURLWithPath: "/fake/lms") }
        content.fetchModels = { self.emptyModelsResponse() }
        content.makeRuntimeStreamProcess = makeSleepForeverProcess
        content.makeModelStreamProcess = { _ in
            let inputLine = self.predictionInputLine(modelIdentifier: "m", timestamp: self.nowMillis())
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "printf '%s\\n' '\(inputLine)'; sleep 60"]
            return process
        }

        content.setUp(visible: true)
        try await Task.sleep(for: .milliseconds(400))

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
        content.cliExecutableURLProvider = { URL(fileURLWithPath: "/fake/lms") }
        content.fetchModels = { self.emptyModelsResponse() }
        content.staleInFlightWindow = 24 * 60 * 60 // don't let the *other* staleness path fire in this test
        content.psPollInterval = .milliseconds(20)
        content.fetchPsEntries = { _ in
            [LMStudioPsEntry(identifier: "m", modelKey: nil, status: box.status, deviceIdentifier: nil, ttlMs: nil)]
        }
        content.makeRuntimeStreamProcess = makeSleepForeverProcess
        content.makeModelStreamProcess = { _ in
            let inputLine = self.predictionInputLine(modelIdentifier: "m", timestamp: self.nowMillis())
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "printf '%s\\n' '\(inputLine)'; sleep 60"]
            return process
        }

        content.setUp(visible: true)
        try await Task.sleep(for: .milliseconds(400))
        #expect(content.inFlight.count == 1)

        box.status = "idle"
        // Give the `lms ps` poll (20ms cadence) time to run at least once
        // more and see a sample timestamp after the in-flight entry started.
        try await Task.sleep(for: .milliseconds(200))
        #expect(content.inFlight.isEmpty)

        content.tearDown()
        // Real subprocesses — await the reap so neither outlives this test
        // (#0354).
        await content.awaitPendingTeardownReapsForTesting()
    }

    // MARK: - Subprocess teardown (review round 1, B3; #0354)

    /// A process that ignores `SIGTERM` outright (unlike a plain `sleep`,
    /// which dies on the default disposition) — used to exercise #0354's
    /// `SIGKILL` escalation path. `exec` replaces the shell's own process
    /// image with `sleep` in place rather than forking it, and `SIG_IGN`
    /// survives `exec`, so the ignored disposition the `trap` set carries
    /// over to `sleep` directly: exactly one process exists at any point,
    /// so `SIGKILL` on that single pid leaves nothing behind. Without
    /// `exec`, `sleep` runs as the shell's forked child and `SIGKILL` on
    /// the shell's own pid orphans it instead.
    private func makeIgnoringSIGTERMProcess(_ url: URL) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "trap '' TERM; exec sleep 60"]
        return process
    }

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

        content.setUp(visible: true)
        try await Task.sleep(for: .milliseconds(200))

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
    /// only to keep the test fast; the assertion on `tearDown()`'s own
    /// elapsed time is what matters, not the specific bound.
    @Test func tearDownReturnsPromptlyEvenWhenBothChildrenIgnoreSIGTERM() async throws {
        final class ProcessBox {
            var model: Process?
            var runtime: Process?
        }
        let box = ProcessBox()

        let content = LMStudioDashboardPaneContent()
        content.cliExecutableURLProvider = { URL(fileURLWithPath: "/fake/lms") }
        content.fetchModels = { self.emptyModelsResponse() }
        content.teardownWaitBound = 0.2
        content.makeModelStreamProcess = { url in
            let process = self.makeIgnoringSIGTERMProcess(url)
            box.model = process
            return process
        }
        content.makeRuntimeStreamProcess = { url in
            let process = self.makeIgnoringSIGTERMProcess(url)
            box.runtime = process
            return process
        }

        content.setUp(visible: true)
        try await Task.sleep(for: .milliseconds(200))

        let model = try #require(box.model)
        let runtime = try #require(box.runtime)
        #expect(model.isRunning)
        #expect(runtime.isRunning)

        let start = ContinuousClock.now
        content.tearDown()
        let elapsed = start.duration(to: .now)

        // The state machine transitions synchronously — that guarantee is
        // unchanged by #0354's fix.
        #expect(content.lifecyclePhase == .tornDown)
        // Nowhere near `teardownWaitBound` (0.2s here): `tearDown()` must
        // not have blocked waiting for either child to exit.
        #expect(elapsed < .milliseconds(50))
        // Immediately after `tearDown()` returns, both children are still
        // alive (they ignore SIGTERM) — proving the wait really was moved
        // off the main actor, not just made faster.
        #expect(model.isRunning)
        #expect(runtime.isRunning)

        await content.awaitPendingTeardownReapsForTesting()

        // Eventually killed/reaped via the SIGKILL escalation, even though
        // neither child ever cooperated with SIGTERM.
        #expect(model.isRunning == false)
        #expect(runtime.isRunning == false)
    }

    /// Same proof for the `setVisible(false)` (hide) path, which tears
    /// down subprocesses without the bounded wait `tearDown()` uses — this
    /// checks that `SIGTERM` alone (no explicit poll) is still enough to
    /// kill a normal `/bin/sh -c "sleep 60"` promptly.
    @Test func hidingActuallyTerminatesBothSubprocesses() async throws {
        final class ProcessBox {
            var model: Process?
            var runtime: Process?
        }
        let box = ProcessBox()

        let content = LMStudioDashboardPaneContent()
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

        content.setUp(visible: true)
        try await Task.sleep(for: .milliseconds(200))
        content.setVisible(false)
        // No bounded wait on this path — give the signal a moment to land.
        try await Task.sleep(for: .milliseconds(200))

        #expect(box.model?.isRunning == false)
        #expect(box.runtime?.isRunning == false)

        content.tearDown()
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
