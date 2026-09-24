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
            process.arguments = ["-c", "printf '%s\\n' 'Streaming logs from LM Studio' '' '\(inputLine)' '\(outputLine)'; exec sleep 60"]
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
            process.arguments = ["-c", "printf '%s\\n' '\(inputLine)'; exec sleep 60"]
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
            process.arguments = ["-c", "printf '%s\\n' '\(inputLine)'; exec sleep 60"]
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
    ///
    /// #0424: waits on `LMStudioSIGTERMIgnoringFixture`'s ready-file
    /// handshake, not a fixed sleep, before capturing `start` — a fixed
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

        content.setUp(visible: true)

        #expect(LMStudioSIGTERMIgnoringFixture.waitForReadyFile(modelReadyURL), "model-stream never installed its SIGTERM trap")
        #expect(LMStudioSIGTERMIgnoringFixture.waitForReadyFile(runtimeReadyURL), "runtime-stream never installed its SIGTERM trap")

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
    /// kill a normal `/bin/sh -c "exec sleep 60"` promptly.
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

        content.setUp(visible: true)
        // Wait for the *last* line sent, not just `inFlight.count == cap`
        // — the count already reads `cap` partway through delivery (every
        // insert past the cap evicts one), so counting alone can't tell
        // "all lines arrived" from "the cap engaged early."
        let lastIdentifier = "m-\(totalSent - 1)"
        await waitUntil(timeoutNanoseconds: 30_000_000_000) {
            content.inFlight.contains { $0.modelIdentifier == lastIdentifier }
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
    }

    // MARK: - #0355: oversized line through the full pipeline

    /// A single NDJSON line far larger than `streamLineByteCap` (an
    /// adversarial or runaway `-s model` line) must not wedge the parser —
    /// the next, normal-sized line must still be parsed correctly.
    @Test func oversizedLineThroughRealPipeIsDroppedAndPipelineRecovers() async throws {
        let content = LMStudioDashboardPaneContent()
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

        content.setUp(visible: true)
        // A generous bound: this test pipes >256 KB of filler through
        // `head`/`tr` before the real assertion-relevant bytes arrive,
        // which can take noticeably longer than the default 15s bound
        // under the full suite's parallel host load (the isolated
        // `swift test --filter` run finishes in well under a second).
        await waitUntil(timeoutNanoseconds: 30_000_000_000) { !content.inFlight.isEmpty }

        // Only the normal-sized line survived; the oversized one never
        // reached the parser as a usable line.
        #expect(content.inFlight.count == 1)
        #expect(content.inFlight.first?.modelIdentifier == "normal")

        content.tearDown()
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
        content.cliExecutableURLProvider = { URL(fileURLWithPath: "/fake/lms") }
        content.fetchModels = { self.emptyModelsResponse() }
        content.makeRuntimeStreamProcess = makeSleepForeverProcess
        content.respawnDelay = .milliseconds(20)
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

        content.setUp(visible: true)
        // Only becomes non-empty once the *respawned* process's line is
        // parsed — the first process's output never contains a `\n`, so it
        // can never produce a parsed line itself. Generous bound for the
        // same reason as `oversizedLineThroughRealPipeIsDroppedAndPipelineRecovers`:
        // >256 KB of filler plus a respawn round-trip, under full-suite
        // parallel host load.
        await waitUntil(timeoutNanoseconds: 30_000_000_000) { !content.inFlight.isEmpty }

        #expect(content.inFlight.count == 1)
        #expect(content.inFlight.first?.modelIdentifier == "after-respawn")
        #expect(spawnCount.value == 2)

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

/// Same shape as `GitStatusPaneContentTests.swift`'s private `waitUntil` —
/// duplicated here rather than shared because that one is file-private and
/// this suite's `#0355` pipeline tests need the same "poll instead of a
/// fixed sleep" pattern: a fixed wait either pads every run with dead time
/// or, if trimmed too far, flakes under host load.
@MainActor
private func waitUntil(
    timeoutNanoseconds: UInt64 = 15_000_000_000,
    sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: () -> Bool
) async {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .nanoseconds(Int64(timeoutNanoseconds)))
    while !condition(), clock.now < deadline {
        await Task.yield()
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    if !condition() {
        Issue.record(
            "waitUntil timed out after \(timeoutNanoseconds / 1_000_000)ms without the condition becoming true",
            sourceLocation: sourceLocation
        )
    }
}
