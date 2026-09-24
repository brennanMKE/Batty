// ProcessStatusPaneContentTests.swift

import Foundation
import Testing
@testable import BattyKit

/// Covers `ProcessStatusPaneContent` (`#0305`) — the `PaneContentLifecycle`
/// conformer that samples another same-uid process's status. Exercises
/// real `ProcessInspector` calls against real processes (this test
/// executor itself, `launchd`, and short-lived spawned children), the same
/// live-process methodology `docs/design/process-status-view.md`'s own
/// spike used, rather than a mock — the whole point of this view is what
/// the *real* kernel will and won't hand back.
///
/// `.serialized` (review round 2, B3) — see `GitStatusPaneContentTests`'s
/// matching doc comment for what this is (and is not) protecting against:
/// this suite in particular also spawns and `waitUntilExit()`s real
/// `/bin/sleep` children from several of *its own* tests
/// (`pinnedTargetTombstonesOnExitAndStopsSampling`,
/// `tombstoningOnTheImmediateSampleNeverSchedulesThePeriodicTask`,
/// `exitedStateShowsTheLastSuccessfulSampleTimeNotTheDetectionTime`), which
/// block the MainActor synchronously for as long as they run — serializing
/// means the timing-sensitive tests in this same suite never get caught
/// mid-wait behind one of those blocking calls from a *sibling* test.
@Suite(.serialized)
@MainActor
struct ProcessStatusPaneContentTests {

    // MARK: - Default sampling cadence (review round 2, N3)

    /// Every other test in this file injects a short `samplingInterval` so
    /// it never has to pay production's real 1s cadence in wall clock —
    /// which means nothing else here would notice a regression to that
    /// default. Pin it directly, instantly, on a default-initialized
    /// instance instead.
    @Test func defaultSamplingIntervalMatchesProductionDesign() {
        let content = ProcessStatusPaneContent(target: nil, tabLookup: { _ in nil })
        #expect(content.samplingIntervalForTesting == .seconds(1))
    }

    // MARK: - No selection

    @Test func noTargetStartsAndStaysNoSelection() {
        let content = ProcessStatusPaneContent(target: nil, tabLookup: { _ in nil })
        #expect(content.hasNoSelection)
        content.setUp(visible: true)
        #expect(content.hasNoSelection)
        #expect(content.lifecyclePhase == .active)
        #expect(content.snapshot == nil)
    }

    // MARK: - Pinned mode: setUp/setVisible/tearDown transitions

    @Test func setUpVisibleSamplesImmediatelyForAPinnedTarget() {
        let content = ProcessStatusPaneContent(target: .pinned(getpid()), tabLookup: { _ in nil })
        content.setUp(visible: true)
        #expect(content.lifecyclePhase == .active)
        #expect(content.hasNoSelection == false)
        #expect(content.snapshot?.pid == getpid())
        #expect(content.runState == .running)
    }

    /// `docs/pane-view-lifecycle.md` §4: "setup must not create work it
    /// would immediately have to suspend" — created hidden goes straight
    /// to `.suspended` and performs no sample.
    @Test func setUpHiddenNeverSamples() {
        let content = ProcessStatusPaneContent(target: .pinned(getpid()), tabLookup: { _ in nil })
        content.setUp(visible: false)
        #expect(content.lifecyclePhase == .suspended)
        #expect(content.snapshot == nil)
    }

    @Test func showingASuspendedPaneSamplesImmediately() {
        let content = ProcessStatusPaneContent(target: .pinned(getpid()), tabLookup: { _ in nil })
        content.setUp(visible: false)
        content.setVisible(true)
        #expect(content.lifecyclePhase == .active)
        #expect(content.snapshot?.pid == getpid())
    }

    @Test func tearDownIsIdempotentAndTerminal() {
        let content = ProcessStatusPaneContent(target: .pinned(getpid()), tabLookup: { _ in nil })
        content.setUp(visible: true)
        content.tearDown()
        #expect(content.lifecyclePhase == .tornDown)
        content.tearDown()
        #expect(content.lifecyclePhase == .tornDown)
        // A rejected event after teardown must not reactivate sampling.
        content.setVisible(true)
        #expect(content.lifecyclePhase == .tornDown)
    }

    /// The real evidence #0289's lesson demands: sampling actually stops
    /// after hide, and actually resumes after show. `#0431`: driven through
    /// an injected `TestClock` (`#0428`) instead of a real wall-clock
    /// cadence — `advance(by:)` fires the periodic sampler's due tick, and
    /// `waitForSleepers(1)` afterward is the real "this tick's
    /// `performSample()` already ran and the loop is back asleep" signal
    /// (`docs/async-test-seams.md` §1's "once per tick" pattern), not a
    /// guess at scheduling order or a fixed sleep. The injected 20ms
    /// interval (non-default; production is 1s) only has to be small
    /// enough that "50 more intervals" below is a cheap virtual-time
    /// advance — it costs no real wall clock either way.
    @Test func samplingStopsWhileSuspendedAndResumesWhenShown() async throws {
        let clock = TestClock()
        let content = ProcessStatusPaneContent(
            target: .pinned(getpid()),
            tabLookup: { _ in nil },
            samplingInterval: .milliseconds(20),
            clock: clock
        )
        // #0431 round 2, B3: without this, an early `return` from either
        // `waitForSleepers` guard below (or just reaching the end of the
        // test with sampling resumed) leaves a `Task` parked on `clock`
        // forever — `TestClock` never lets time pass on its own, so
        // nothing else would ever wake or cancel it.
        defer { content.tearDown() }
        content.setUp(visible: true)
        let firstCapture = try #require(content.snapshot?.capturedAt)

        guard await clock.waitForSleepers(1) else {
            Issue.record("waitForSleepers(1) never reached its threshold before the first tick")
            return
        }
        await clock.advance(by: .milliseconds(20))
        guard await clock.waitForSleepers(1) else {
            Issue.record("waitForSleepers(1) never reached its threshold after the first tick")
            return
        }
        let secondCapture = try #require(content.snapshot?.capturedAt)
        #expect(secondCapture > firstCapture)

        content.setVisible(false)
        // Hiding cancels the pending sleep synchronously — `TestClock
        // .sleep(for:)` wraps its continuation in
        // `withTaskCancellationHandler`, so the sleeper is removed and
        // resumed as part of this same `Task.cancel()` call, before
        // `setVisible` even returns (`docs/async-test-seams.md` §1).
        #expect(clock.pendingCount == 0, "hiding must cancel the pending sleep synchronously, not just eventually")
        let capturedAtHideTime = content.snapshot?.capturedAt

        // Advance many sampling intervals while hidden (review round 2,
        // B5's "nothing sampled while hidden" guarantee — comment
        // preserved from the pre-#0431 version: this is not merely
        // proving `.cancel()` was called; the periodic loop's own
        // `guard lifecyclePhase == .active` would already stop a *leaked*
        // Task on its next tick regardless of cancellation, and mutation
        // M5 removes both guards together). Unlike a fixed wall-clock
        // window, this can't miss a leaked loop: every loop goes through
        // this same scheduler, so a leaked `Task` would still be parked on
        // `clock.sleep(for:)` and this advance would fire it.
        _ = await clock.advance(by: .milliseconds(20 * 50))
        #expect(content.snapshot?.capturedAt == capturedAtHideTime)
        #expect(clock.pendingCount == 0, "advancing while hidden must not schedule anything new")

        content.setVisible(true)
        // The resume-and-refresh sample runs synchronously inside
        // `setVisible` itself (`startSampling` calls `performSample()`
        // before scheduling the next tick) — no wait needed.
        let resumedCapture = try #require(content.snapshot?.capturedAt)
        #expect(resumedCapture > capturedAtHideTime!)
    }

    // MARK: - Permission-denied state (§3.5)

    @Test func permissionDeniedShowsPathAndBasenameFallbackButNoMetricsOrCommandLine() {
        let content = ProcessStatusPaneContent(target: .pinned(1), tabLookup: { _ in nil }) // launchd
        content.setUp(visible: true)
        #expect(content.runState == .permissionDenied)
        #expect(content.snapshot?.executablePath != nil)
        #expect(content.snapshot?.name == "launchd")
        #expect(content.snapshot?.commandLine == nil)
        #expect(content.snapshot?.cpuPercent == nil)
    }

    // MARK: - Unavailable state on an unexpected errno (#0356)

    /// #0356's core regression: `.failure(.unexpected(errno:))` used to be
    /// log-only, leaving `runState` at whatever it was before (`.running`
    /// on a pane that had already sampled successfully at least once) —
    /// the chip kept claiming "Running" over a snapshot that had stopped
    /// updating. There is no live process this codebase has ever observed
    /// producing a real `.unexpected` errno (every real failure is
    /// `ESRCH`/`EPERM`), so this drives it through the injected
    /// `coreMetricsProvider` seam rather than hunting for one.
    @Test func unexpectedSampleFailureFlipsToUnavailableAndKeepsTheLastKnownSnapshot() {
        var shouldFail = false
        let content = ProcessStatusPaneContent(
            target: .pinned(getpid()),
            tabLookup: { _ in nil },
            coreMetricsProvider: { pid in
                shouldFail ? .failure(.unexpected(errno: 99)) : ProcessInspector.coreMetrics(pid: pid)
            }
        )
        content.setUp(visible: true)
        #expect(content.runState == .running)
        let lastGoodSnapshot = content.snapshot
        #expect(lastGoodSnapshot != nil)

        shouldFail = true
        content.sampleNowForTesting()

        #expect(content.runState == .unavailable)
        // The last successful sample is kept, not cleared — "what it was,"
        // matching `.exited`'s own tombstone shape (`.permissionDenied` is
        // different: it replaces `snapshot` with a fresh identity-only one
        // rather than keeping the prior one — see that branch's own test).
        #expect(content.snapshot == lastGoodSnapshot)
    }

    /// S1: `.unexpected` must reset the CPU baseline (`cpuTracker.reset()`)
    /// so a later recovery doesn't delta the recovery sample's CPU ticks
    /// against a baseline taken before the gap — deleting that
    /// `cpuTracker.reset()` call passes every other test in this file, so
    /// this drives the reset through observable behavior directly: the
    /// first sample after recovering has no prior baseline, exactly like
    /// the very first sample of a fresh `ProcessStatusPaneContent`.
    @Test func unavailableResetsTheCPUBaselineSoRecoveryHasNoStaleDelta() {
        var shouldFail = false
        let content = ProcessStatusPaneContent(
            target: .pinned(getpid()),
            tabLookup: { _ in nil },
            coreMetricsProvider: { pid in
                shouldFail ? .failure(.unexpected(errno: 99)) : ProcessInspector.coreMetrics(pid: pid)
            }
        )
        content.setUp(visible: true)
        #expect(content.snapshot?.cpuPercent == nil, "no prior baseline yet on the very first sample")

        shouldFail = true
        content.sampleNowForTesting()
        #expect(content.runState == .unavailable)

        shouldFail = false
        content.sampleNowForTesting()

        #expect(content.runState == .running)
        #expect(content.snapshot?.cpuPercent == nil, "cpuTracker.reset() in the .unexpected branch means the recovery sample has no prior baseline either — without it, this would delta against the pre-failure baseline instead")
    }

    /// A transient errno must self-heal: the periodic sampling `Task` is
    /// never cancelled on `.unexpected` (unlike `.processNotFound`), so a
    /// later successful sample flips `runState` straight back to
    /// `.running` with a fresh snapshot — no distinct "recovery" action
    /// needed.
    @Test func unavailableRecoversToRunningOnTheNextSuccessfulSample() {
        var shouldFail = true
        let content = ProcessStatusPaneContent(
            target: .pinned(getpid()),
            tabLookup: { _ in nil },
            coreMetricsProvider: { pid in
                shouldFail ? .failure(.unexpected(errno: 99)) : ProcessInspector.coreMetrics(pid: pid)
            }
        )
        content.setUp(visible: true)
        #expect(content.runState == .unavailable)
        #expect(content.snapshot == nil, "never sampled successfully yet — nothing to have shown before the failure")

        shouldFail = false
        content.sampleNowForTesting()

        #expect(content.runState == .running)
        #expect(content.snapshot?.pid == getpid())
    }

    /// The periodic sampling `Task` must still be alive after an
    /// `.unexpected` failure — the design decision this issue makes is
    /// retry (not tombstone): sampling keeps ticking so a persistent
    /// failure keeps showing `.unavailable` freshly rather than freezing,
    /// and a transient one can recover on its own.
    @Test func unavailableDoesNotCancelThePeriodicSamplingTask() {
        let content = ProcessStatusPaneContent(
            target: .pinned(getpid()),
            tabLookup: { _ in nil },
            coreMetricsProvider: { _ in .failure(.unexpected(errno: 99)) }
        )
        content.setUp(visible: true)
        #expect(content.runState == .unavailable)
        #expect(content.isSamplingTaskAlive, "an unexpected errno must keep retrying, unlike a confirmed .processNotFound exit")
    }

    // MARK: - Exited / tombstone state (§3.6), pinned mode

    @Test func pinnedTargetTombstonesOnExitAndStopsSampling() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["0.05"]
        try process.run()
        let pid = process.processIdentifier
        process.waitUntilExit()

        let content = ProcessStatusPaneContent(target: .pinned(pid), tabLookup: { _ in nil })
        content.setUp(visible: true)
        guard case .exited = content.runState else {
            Issue.record("expected .exited, got \(content.runState)")
            return
        }

        // Once tombstoned, hide/show must not resurrect sampling.
        content.setVisible(false)
        content.setVisible(true)
        guard case .exited = content.runState else {
            Issue.record("expected .exited to stick, got \(content.runState)")
            return
        }
    }

    // MARK: - Mode B: following a Tab

    @Test func followingATabWithNoForegroundPidIsNoSelectionNotTombstone() {
        let tab = TabRuntime()
        let content = ProcessStatusPaneContent(target: .followingTab(tab.id), tabLookup: { id in
            id == tab.id ? tab : nil
        })
        content.setUp(visible: true)
        // `terminalNSView` is nil in this headless test — no AppKit surface
        // was ever attached — so `foregroundPid` is nil: "no selection,"
        // not "the tab is gone."
        #expect(content.hasNoSelection)
        guard case .running = content.runState else {
            Issue.record("expected .running (no-selection doesn't touch runState), got \(content.runState)")
            return
        }
    }

    @Test func followingATabTombstonesWhenTheTabLookupMisses() {
        let missingTabID = UUID()
        let content = ProcessStatusPaneContent(target: .followingTab(missingTabID), tabLookup: { _ in nil })
        content.setUp(visible: true)
        guard case .exited = content.runState else {
            Issue.record("expected .exited, got \(content.runState)")
            return
        }
        #expect(content.hasNoSelection == false)
    }

    // MARK: - Retargeting (§2's "Choose Process…")

    @Test func retargetResetsStateAndSamplesTheNewTargetImmediatelyWhileActive() {
        let content = ProcessStatusPaneContent(target: nil, tabLookup: { _ in nil })
        content.setUp(visible: true)
        #expect(content.hasNoSelection)

        content.retarget(to: .pinned(getpid()))
        #expect(content.hasNoSelection == false)
        #expect(content.snapshot?.pid == getpid())
        #expect(content.lifecyclePhase == .active)
    }

    @Test func retargetWhileSuspendedDoesNotSampleUntilShown() {
        let content = ProcessStatusPaneContent(target: nil, tabLookup: { _ in nil })
        content.setUp(visible: false)
        content.retarget(to: .pinned(getpid()))
        #expect(content.lifecyclePhase == .suspended)
        #expect(content.snapshot == nil)
    }

    @Test func watchInsteadPinsToTheGivenChildPid() {
        let content = ProcessStatusPaneContent(target: .pinned(1), tabLookup: { _ in nil })
        content.setUp(visible: true)
        #expect(content.runState == .permissionDenied)

        content.watchInstead(pid: getpid())
        #expect(content.target == .pinned(getpid()))
        #expect(content.snapshot?.pid == getpid())
        #expect(content.runState == .running)
    }

    // MARK: - CPU% correctness (review round 1, B1) — a real value, not
    // just "some Optional got set"

    /// The direct regression test for B1: `ri_user_time`/`ri_system_time`
    /// are mach-absolute-time ticks, not nanoseconds, and treating them as
    /// nanoseconds under-reported CPU% by ~42x (2.4% measured vs. the
    /// correct ~99.97% for a process pegging one core). This burns real
    /// CPU between two samples and asserts the *value*, not merely that
    /// `cpuPercent` is non-nil — a test that only checked "is a Double
    /// present" is exactly the shape of test that let B1 ship in round 1.
    ///
    /// Review round 2, B4: a fixed floor on `cpuPercent` (originally
    /// `> 10`) is a claim about how much of a *shared* core this process
    /// got — a quantity a sufficiently loaded machine can legitimately
    /// drive below any fixed floor without `ProcessCPUDeltaTracker` being
    /// wrong at all (measured 9.55%/8.56% under ~30-process contention
    /// during that review, both genuine, both below the old floor). This
    /// version instead recomputes the expected percentage from the same
    /// raw kernel ticks production itself saw, and checks production's
    /// answer against *that*, not against a magnitude assumption about the
    /// host machine. A B1-class ~42x scaling bug fails this at any
    /// contention level; a merely-busy shared machine does not.
    ///
    /// `#0431`: rewritten to remove every wall-clock dependency the
    /// original had. The workload is a *fixed amount of work* (a constant
    /// iteration count), not a `while Date() < deadline` time span, and the
    /// interval the percentage is computed over is an explicit
    /// `TestClock.advance(by:)` amount rather than a `Date()` bracket —
    /// feeding `ProcessCPUDeltaTracker` its `at:` timestamps from the
    /// injected clock (`#0428`).
    ///
    /// #0431 round 2, B2: an earlier version of this rewrite called
    /// ``cpuPercent(for:)`` directly with hand-built `ProcessSample`s,
    /// bypassing `sample(pid:)` entirely — which let two real mutations
    /// pass: `cpuPercent` hardcoded to `nil` in `sample(pid:)`'s `.success`
    /// branch, and `cpuTicksUser` dropped when that branch builds its
    /// `ProcessSample`. Neither mutation sits on the path a direct
    /// `cpuPercent(for:)` call exercises. This version goes through the
    /// real path instead — `setUp`/`sampleNowForTesting`, which call
    /// `sample(pid:)`, which calls `cpuPercent(for:)` internally — with a
    /// recording `coreMetricsProvider` that still calls the real
    /// `ProcessInspector.coreMetrics` but records each result. So this test
    /// pins production's own tracker math and clock wiring against the
    /// exact ticks `sample(pid:)` itself read, rather than an independent
    /// second `ProcessInspector.coreMetrics` call of its own (which is what
    /// let the two mutations above hide: a *second*, separate read can't
    /// see what production's own call returned).
    ///
    /// `samplingInterval` is set far longer than the 1-second `advance(by:)`
    /// below, deliberately: production's own periodic sampling `Task` is
    /// also parked on this same `TestClock`, and if its interval matched
    /// the advance exactly, that advance would fire *two* samples (the
    /// periodic tick and this test's own `sampleNowForTesting()`) in an
    /// order this test doesn't control, corrupting which two recorded
    /// metrics are "before" and "after" the burn.
    @Test func cpuPercentReflectsSubstantialRealCoreUsage() async throws {
        let clock = TestClock()
        var recordedMetrics: [ProcessInspector.CoreMetrics] = []
        let content = ProcessStatusPaneContent(
            target: .pinned(getpid()),
            tabLookup: { _ in nil },
            samplingInterval: .seconds(60),
            coreMetricsProvider: { pid in
                let result = ProcessInspector.coreMetrics(pid: pid)
                if case .success(let metrics) = result {
                    recordedMetrics.append(metrics)
                }
                return result
            },
            clock: clock
        )
        defer { content.tearDown() }
        content.setUp(visible: true) // establishes the CPU baseline; cpuPercent is nil on this first sample
        #expect(content.snapshot?.cpuPercent == nil, "no prior baseline yet on the very first sample")

        // Burn a fixed amount of real CPU — a constant iteration count,
        // not a time span (#0431), and cheap per-iteration arithmetic
        // rather than `Double.random` (#0431 round 2) — on a *detached*
        // task, off this package's MainActor: this suite runs alongside
        // ~1100 other tests, several of which are themselves
        // MainActor-isolated, and MainActor is one serial queue, so a
        // tight synchronous loop running *on* it would starve every other
        // MainActor-isolated test in the same parallel batch for its whole
        // duration (observed directly when an earlier version of this test
        // spun inline). The CPU time still accrues to this same process
        // (`getpid()`) regardless of which thread burns it, so the
        // measurement is unaffected.
        await Task.detached(priority: .userInitiated) {
            var sink: Double = 0
            for i in 0..<1_000_000 {
                sink += Foundation.sqrt(Double(i % 97) + 1)
            }
            _ = sink
        }.value

        // An arbitrary but explicit interval — not measured from wall
        // clock — that both production's own tracker and this test's
        // recomputation divide by.
        _ = await clock.advance(by: .seconds(1))
        content.sampleNowForTesting()

        let cpuPercent = try #require(content.snapshot?.cpuPercent)

        guard recordedMetrics.count >= 2 else {
            Issue.record("expected at least 2 recorded coreMetrics calls (baseline + post-burn sample), got \(recordedMetrics.count)")
            return
        }
        let before = recordedMetrics[recordedMetrics.count - 2]
        let after = recordedMetrics[recordedMetrics.count - 1]
        let deltaTicks = (after.cpuTicksUser &+ after.cpuTicksSystem)
            &- (before.cpuTicksUser &+ before.cpuTicksSystem)
        try #require(deltaTicks > 0, "the fixed CPU burn above must have produced measurable ticks")

        let deltaSeconds = Double(deltaTicks) * MachTimebase.nanosecondsPerTick / 1_000_000_000
        let expectedPercent = deltaSeconds * 100 // interval == 1 second

        // A tight tolerance, not the old 5x band — both sides now share
        // the exact same recorded ticks and the exact same interval, so
        // the only remaining slack is floating-point rounding, not
        // scheduling or bracketing skew. A B1-class ~42x scaling bug fails
        // this by orders of magnitude either way.
        #expect(
            abs(cpuPercent - expectedPercent) < 0.001,
            "production cpuPercent (\(cpuPercent)) diverges from the recomputed expectation (\(expectedPercent)) from the same recorded ticks over the same interval — looks like a B1-class ticks-as-nanoseconds regression"
        )
    }

    // MARK: - Cross-pid CPU delta (review round 1, B2)

    /// `#0314` merge: the pid-keyed CPU-delta baseline now lives in the
    /// shared `ProcessCPUDeltaTracker` (fed one `ProcessSample` per tick
    /// via `ProcessStatusPaneContent.cpuPercent(for:)`), not a hand-rolled
    /// dictionary — this pins the same B2 property (a pid change resets
    /// the baseline rather than delta-ing across two different
    /// processes' CPU totals) through that real integration point,
    /// tested directly rather than only through mode B (which needs a
    /// live AppKit `foregroundPid` this headless target can't produce).
    @Test func cpuPercentResetsTheBaselineWhenThePidChanges() {
        let content = ProcessStatusPaneContent(target: .pinned(getpid()), tabLookup: { _ in nil })

        func sample(pid: pid_t, ticksUser: UInt64) -> ProcessSample {
            ProcessSample(
                pid: pid,
                name: "test",
                path: nil,
                threadCount: 1,
                physFootprintBytes: 0,
                residentSizeBytes: 0,
                cpuTicksUser: ticksUser,
                cpuTicksSystem: 0
            )
        }

        let first = content.cpuPercent(for: sample(pid: getpid(), ticksUser: 1_000_000))
        #expect(first == nil, "no prior baseline yet")

        let second = content.cpuPercent(for: sample(pid: getpid(), ticksUser: 1_500_000))
        #expect(second != nil, "same pid, later sample — should delta normally")

        // A different pid's next sample must not delta against the first
        // pid's accumulated total, no matter how large a jump that would
        // imply — B2's cross-pid bug.
        let otherPid = getpid() &+ 1
        let crossPid = content.cpuPercent(for: sample(pid: otherPid, ticksUser: 999_999_999))
        #expect(crossPid == nil, "a pid change must reset the baseline, not compute a delta across two different processes' CPU totals")
    }

    // MARK: - Tombstone does not resample a second time (review round 1, B4)

    /// The empirical bug review round 1 found: `startSampling()` guarded
    /// `runState` *before* the immediate `performSample()` call but not
    /// after, so a target that tombstones on its very first sample still
    /// went on to schedule the periodic `Task` — which woke up ~1s later,
    /// re-detected the same exit, and silently overwrote the first (and
    /// only correct) detection. Checked structurally
    /// (`isSamplingTaskAlive`), not just by re-reading `runState` after a
    /// wait, so a regression is caught even if a future change makes the
    /// second detection idempotent in some other way.
    @Test func tombstoningOnTheImmediateSampleNeverSchedulesThePeriodicTask() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["0.05"]
        try process.run()
        let pid = process.processIdentifier
        process.waitUntilExit()

        let content = ProcessStatusPaneContent(target: .pinned(pid), tabLookup: { _ in nil })
        content.setUp(visible: true)
        guard case .exited = content.runState else {
            Issue.record("expected .exited, got \(content.runState)")
            return
        }
        #expect(content.snapshot == nil, "never sampled successfully — nothing to have shown before the exit")
        #expect(content.isSamplingTaskAlive == false, "B4: the periodic Task must never be scheduled after the immediate sample already tombstoned")
    }

    // MARK: - `.exited` shows the last successful sample's time, not the
    // detection time (review round 1, B5)

    @Test func exitedStateShowsTheLastSuccessfulSampleTimeNotTheDetectionTime() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["0.4"]
        try process.run()
        let pid = process.processIdentifier

        let content = ProcessStatusPaneContent(target: .pinned(pid), tabLookup: { _ in nil })
        content.setUp(visible: true) // the process is still alive here
        guard case .running = content.runState else {
            Issue.record("precondition failed: expected .running before the process exits")
            return
        }
        let lastGoodCapture = try #require(content.snapshot?.capturedAt)

        process.waitUntilExit()
        content.sampleNowForTesting()

        guard case .exited = content.runState else {
            Issue.record("expected .exited, got \(content.runState)")
            return
        }
        // B5: must be the time of the last successful sample (captured
        // while the process was still alive), never a fresh `Date()`
        // stamped at the moment the exit was merely detected.
        #expect(content.snapshot?.capturedAt == lastGoodCapture)
    }

    // MARK: - The sampling Task reference is actually released, not just
    // "phase says so" (review round 1's general test-gap finding)

    /// Named for what this actually checks (review round 3, N2 — the
    /// original name, "...ActuallyCancels...", claimed more than the
    /// assertion below can back up): `isSamplingTaskAlive == false` proves
    /// the `samplingTask` reference was released, which is exactly what
    /// catches "hide forgot to call `stopSampling()` at all" (the original
    /// round 1 regression this test exists for) — but it is silent on
    /// whether the `Task` was actually `.cancel()`-ed before that
    /// reference was dropped. Mutation-tested (M6) and confirmed: dropping
    /// `.cancel()` from `stopSampling()` while still nil-ing the reference
    /// passes this test, because the periodic loop's own
    /// `lifecyclePhase == .active` guard independently stops it from
    /// sampling again regardless. That gap is real, disclosed, and not
    /// what this test claims to cover.
    @Test func hidingReleasesTheSamplingTaskReferenceNotJustTheObservablePhase() {
        let content = ProcessStatusPaneContent(target: .pinned(getpid()), tabLookup: { _ in nil })
        content.setUp(visible: true)
        #expect(content.isSamplingTaskAlive)

        content.setVisible(false)
        #expect(content.isSamplingTaskAlive == false, "review round 1: removing stopSampling() from the hide path left the equivalent behavioral test passing anyway, because the loop's own lifecyclePhase guard alone was enough — this checks the Task reference directly")
    }

    @Test func tearDownReleasesTheSamplingTaskReference() {
        let content = ProcessStatusPaneContent(target: .pinned(getpid()), tabLookup: { _ in nil })
        content.setUp(visible: true)
        #expect(content.isSamplingTaskAlive)

        content.tearDown()
        #expect(content.isSamplingTaskAlive == false)
    }

    // MARK: - Disclosure content honesty (#0357)
    //
    // `openFilesState`/`childProcessesState` must never collapse "never
    // asked," "asked, kernel refused," and "asked, here is the real
    // (possibly empty) answer" into a single measured-looking value — that
    // collapse (`?? []` feeding a `DisclosureGroup`'s `(0)` label) was the
    // bug this issue fixed. Each state below is driven the same way the
    // rest of this file drives `runState` itself: real processes for
    // `.running`/`.exited`/`.permissionDenied`, the injected
    // `coreMetricsProvider` seam for `.unavailable` (no real process in
    // this codebase has ever produced that errno).

    @Test func runningBeforeFirstExpansionIsNotLoadedNotAZero() {
        let content = ProcessStatusPaneContent(target: .pinned(getpid()), tabLookup: { _ in nil })
        content.setUp(visible: true)
        #expect(content.runState == .running)
        #expect(content.openFilesState == .notLoaded)
        #expect(content.childProcessesState == .notLoaded)
    }

    @Test func loadOpenFilesForARunningSameUserProcessYieldsLoadedNotUnavailable() {
        let content = ProcessStatusPaneContent(target: .pinned(getpid()), tabLookup: { _ in nil })
        content.setUp(visible: true)

        content.loadOpenFiles()

        guard case .loaded = content.openFilesState else {
            Issue.record("expected .loaded for a same-uid running process, got \(content.openFilesState)")
            return
        }
    }

    @Test func loadChildProcessesForARunningProcessYieldsLoaded() {
        let content = ProcessStatusPaneContent(target: .pinned(getpid()), tabLookup: { _ in nil })
        content.setUp(visible: true)

        content.loadChildProcesses()

        guard case .loaded = content.childProcessesState else {
            Issue.record("expected .loaded (even if the list is empty), got \(content.childProcessesState)")
            return
        }
    }

    /// The direct regression test for problem 1 in the issue: a dead pid's
    /// `listOpenFileDescriptors` call returns `nil` (`ESRCH`) — that must
    /// surface as `.unavailable`, never as `.loaded([])`, which would read
    /// on screen as a confident, measured "Open Files (0)" for a process
    /// that no longer exists to measure.
    @Test func loadOpenFilesForAnExitedProcessIsUnavailableNeverALoadedZero() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["0.05"]
        try process.run()
        let pid = process.processIdentifier
        process.waitUntilExit()

        let content = ProcessStatusPaneContent(target: .pinned(pid), tabLookup: { _ in nil })
        content.setUp(visible: true)
        guard case .exited = content.runState else {
            Issue.record("expected .exited, got \(content.runState)")
            return
        }

        content.loadOpenFiles()

        #expect(content.openFilesState == .unavailable, "a dead pid's fd listing must be .unavailable, never a fabricated .loaded([])")
    }

    /// `.permissionDenied`'s `snapshot` still carries a real pid (§1.6 —
    /// identity resolves even though metrics don't), so `loadOpenFiles()`
    /// still attempts the real call — which fails `EPERM` for a
    /// different-uid target, distinct from the exited case's `ESRCH`, but
    /// the same honest `.unavailable` outcome.
    @Test func loadOpenFilesForAPermissionDeniedProcessIsUnavailable() {
        let content = ProcessStatusPaneContent(target: .pinned(1), tabLookup: { _ in nil }) // launchd
        content.setUp(visible: true)
        #expect(content.runState == .permissionDenied)

        content.loadOpenFiles()

        #expect(content.openFilesState == .unavailable)
    }

    /// Pins content-layer behavior only — `ProcessStatusPaneView` hides the
    /// whole `disclosures` section outside `.running`, so this call path
    /// never actually reaches the screen while `runState == .unavailable`.
    /// What this test protects is `loadOpenFiles()`'s own contract: it must
    /// key strictly off the real `ProcessInspector` call's own success or
    /// failure, never off `runState`, because `.unavailable` (#0356's
    /// unexpected-errno state) only means the *core metrics* sample
    /// failed — `listOpenFileDescriptors` is a separate, unmocked
    /// `ProcessInspector` call, so for a still-alive, still-readable pid it
    /// can genuinely succeed even while `runState` reads `.unavailable`.
    /// If a future change ever gates `loadOpenFiles()` on `runState`
    /// directly (rather than the view gating whether the section is shown
    /// at all), this test would catch that regression at the content layer
    /// even though the view-level symptom would be invisible today.
    @Test func loadOpenFilesStillWorksForALivePidWhoseCoreMetricsSampleIsUnavailable() {
        var shouldFail = false
        let content = ProcessStatusPaneContent(
            target: .pinned(getpid()),
            tabLookup: { _ in nil },
            coreMetricsProvider: { pid in
                shouldFail ? .failure(.unexpected(errno: 99)) : ProcessInspector.coreMetrics(pid: pid)
            }
        )
        content.setUp(visible: true) // establishes a real snapshot (with this live pid) first
        #expect(content.runState == .running)

        shouldFail = true
        content.sampleNowForTesting()
        #expect(content.runState == .unavailable)
        #expect(content.snapshot?.pid == getpid(), "the last-known snapshot (and its pid) is kept, not cleared, on .unexpected")

        content.loadOpenFiles()

        guard case .loaded = content.openFilesState else {
            Issue.record("expected .loaded for this still-alive, still-readable pid, got \(content.openFilesState)")
            return
        }
    }

    @Test func retargetResetsDisclosureStateToNotLoaded() {
        let content = ProcessStatusPaneContent(target: .pinned(getpid()), tabLookup: { _ in nil })
        content.setUp(visible: true)
        content.loadOpenFiles()
        content.loadChildProcesses()
        guard case .loaded = content.openFilesState else {
            Issue.record("precondition failed: expected .loaded before retargeting")
            return
        }

        content.retarget(to: .pinned(1)) // launchd

        #expect(content.openFilesState == .notLoaded, "a disclosure loaded for the old target must not linger and be shown as if it described the new one")
        #expect(content.childProcessesState == .notLoaded)
    }

    /// The direct regression test for review round 1's B1: retargeting (or
    /// its `watchInstead(pid:)` special case) while Child Processes is
    /// still expanded must not leave the section stuck on `.notLoaded`
    /// ("Loading…" forever, since nothing re-expands it to trigger another
    /// load) — the content object must reload it immediately for the new
    /// pid as part of the same retarget, because `watchInstead` is reached
    /// from a button *inside* the expanded Child Processes body itself, so
    /// this exact sequence happens on every real use of that affordance.
    ///
    /// Injects a `.success` sample for the watched pid (an arbitrary pid
    /// nothing else in this process tree owns, so there is no ambiguity
    /// about which branch produced the result) so the pane lands in
    /// `.running` — the only state `ProcessStatusPaneView` shows
    /// disclosures in, and the branch of `sample(pid:)` that resets and
    /// reloads them.
    @Test func watchInsteadWhileChildProcessesIsExpandedReloadsForTheNewPidRatherThanStickingOnNotLoaded() {
        let watchedPid: pid_t = 424_242
        let content = ProcessStatusPaneContent(
            target: .pinned(getpid()),
            tabLookup: { _ in nil },
            coreMetricsProvider: { pid in
                pid == watchedPid
                    ? .success(ProcessInspector.CoreMetrics(residentBytes: 0, physFootprintBytes: 0, threadCount: 1, openFileCount: 0, cpuTicksUser: 0, cpuTicksSystem: 0))
                    : ProcessInspector.coreMetrics(pid: pid)
            }
        )
        content.setUp(visible: true)
        content.setChildProcessesExpanded(true)
        guard case .loaded = content.childProcessesState else {
            Issue.record("precondition failed: expected .loaded before watching a different pid")
            return
        }

        content.watchInstead(pid: watchedPid)

        #expect(content.runState == .running, "the injected provider must answer .success for the watched pid, landing sample(pid:) in the .success branch this test targets — not .permissionDenied/.exited")
        #expect(content.isChildrenExpanded, "the section's own expansion state must survive the retarget")
        guard case .loaded = content.childProcessesState else {
            Issue.record("expected an immediate reload to .loaded for the watched pid, got \(content.childProcessesState) — an expanded section must not stick on .notLoaded until manually collapsed and re-expanded")
            return
        }
    }
}
