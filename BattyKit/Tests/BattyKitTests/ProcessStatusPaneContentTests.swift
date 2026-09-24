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

    /// Polls instead of trusting a single fixed sleep — this suite runs
    /// alongside ~1100 other tests, several of which spawn real
    /// subprocesses and block synchronously (`Process.waitUntilExit()`),
    /// which can starve the cooperative thread pool and delay a `Task`'s
    /// resumption well past its nominal `Task.sleep` duration. A generous
    /// polling budget tolerates that scheduling jitter without weakening
    /// what's actually being asserted (a real state change did happen).
    /// 15s, back down from round 2's 30s (review round 3, N1) — see
    /// `GitStatusPaneContentTests`'s matching `waitUntil` doc comment for
    /// the full reasoning: 30s was compensating for *misattribution*,
    /// which loud `Issue.record` on timeout (below) now fixes directly,
    /// and for starvation this suite's own `.serialized` (above) now
    /// measurably removes. A smaller ceiling costs a passing run nothing
    /// and a genuine hang less time to report.
    /// Records a loud `Issue` on timeout rather than silently returning,
    /// so a caller with a downstream `#expect` fails at the wait, not on
    /// an unrelated expectation that misattributes starvation as a
    /// behavioral regression.
    private func waitUntil(
        timeout: Duration = .seconds(15),
        sourceLocation: SourceLocation = #_sourceLocation,
        _ condition: () -> Bool
    ) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
        if !condition() {
            Issue.record(
                "waitUntil timed out after \(timeout) without the condition becoming true",
                sourceLocation: sourceLocation
            )
        }
    }

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
    /// after hide, and actually resumes after show — checked by letting
    /// wall-clock time pass across a real cadence rather than trusting
    /// that `setVisible` was called. Uses an injected 20ms cadence (the
    /// production default is 1s) so this stays a real-timing test without
    /// paying production's cadence in wall clock — the negative-assertion
    /// wait below still spans several full cadences (a genuine "did
    /// anything happen" window, not a token gesture), it just does so at
    /// 1/50th the real duration.
    @Test func samplingStopsWhileSuspendedAndResumesWhenShown() async throws {
        let content = ProcessStatusPaneContent(target: .pinned(getpid()), tabLookup: { _ in nil }, samplingInterval: .milliseconds(20))
        content.setUp(visible: true)
        let firstCapture = try #require(content.snapshot?.capturedAt)

        await waitUntil { (content.snapshot?.capturedAt ?? firstCapture) > firstCapture }
        let secondCapture = try #require(content.snapshot?.capturedAt)
        #expect(secondCapture > firstCapture)

        content.setVisible(false)
        let capturedAtHideTime = content.snapshot?.capturedAt

        // A real wait, comfortably longer (10x) than the injected 20ms
        // cadence. Review round 2, B5 correction: this is *not* protecting
        // against a regression that merely forgot to call `.cancel()`
        // before dropping the `Task` reference — mutation-tested (M6) and
        // confirmed that specific bug passes with or without this wait,
        // and with or without the structural `isSamplingTaskAlive` check
        // `hidingReleasesTheSamplingTaskReferenceNotJustTheObservablePhase`
        // makes below, because the periodic loop's own
        // `guard lifecyclePhase == .active` already returns on its next
        // tick regardless of cancellation. What this wait *does* catch
        // (mutation-tested, M5-equivalent) is the more literal regression
        // `docs/pane-view-lifecycle.md` §4 names — hiding not actually
        // stopping periodic sampling at all (both the phase guard and the
        // cancellation gone) — which no structural check can see, since a
        // leaked loop isn't held in `samplingTask` either way. Kept real
        // (not converted to a pure structural check) for that reason; kept
        // cheap by riding the same injected-interval seam (200ms spans 10
        // cadences here, where the original 1.5s spanned 1.5 production
        // cadences). Not re-asserting `isSamplingTaskAlive` here (review
        // round 2, N6) — that dedicated test already covers it.
        try await Task.sleep(for: .milliseconds(200))
        #expect(content.snapshot?.capturedAt == capturedAtHideTime)

        content.setVisible(true)
        // The resume-and-refresh sample runs synchronously inside
        // `setVisible` itself (`startSampling` calls `performSample()`
        // before scheduling the next tick) — `waitUntil` here is
        // defensive headroom, not a requirement for correctness.
        await waitUntil { (content.snapshot?.capturedAt ?? capturedAtHideTime!) > capturedAtHideTime! }
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
    /// correct ~99.97% for a process pegging one core). This busy-loops
    /// real CPU for real wall-clock time between two samples and asserts
    /// the *value*, not merely that `cpuPercent` is non-nil — a test that
    /// only checked "is a Double present" is exactly the shape of test
    /// that let B1 ship in round 1.
    ///
    /// Review round 2, B4: a fixed floor on `cpuPercent` (originally
    /// `> 10`) is a claim about how much of a *shared* core this process
    /// got — a quantity a sufficiently loaded machine can legitimately
    /// drive below any fixed floor without `ProcessCPUDeltaTracker` being
    /// wrong at all (measured 9.55%/8.56% under ~30-process contention
    /// during that review, both genuine, both below the old floor). This
    /// version instead independently re-derives the expected percentage
    /// from the same raw kernel ticks (`ProcessInspector.coreMetrics`,
    /// bracketing the busy loop the same way `ProcessCPUDeltaTracker`
    /// does internally) and checks production's answer against *that*,
    /// not against a magnitude assumption about the host machine. A B1-
    /// class ~42x scaling bug fails this at any contention level; a
    /// merely-busy shared machine does not.
    @Test func cpuPercentReflectsSubstantialRealCoreUsage() async throws {
        let content = ProcessStatusPaneContent(target: .pinned(getpid()), tabLookup: { _ in nil })
        content.setUp(visible: true) // establishes the CPU baseline; cpuPercent is nil on this first sample

        let beforeMetrics = try ProcessInspector.coreMetrics(pid: getpid()).get()
        let beforeTime = Date()

        // Burn real CPU on a *detached* task, off this package's MainActor
        // — this suite runs alongside ~1100 other tests, several of which
        // are themselves MainActor-isolated, and MainActor is one serial
        // queue: a tight synchronous loop running *on* it would starve
        // every other MainActor-isolated test in the same parallel batch
        // for its whole duration (this was observed directly: adding this
        // test as originally written, spinning inline, made the
        // unrelated `samplingStopsWhileSuspendedAndResumesWhenShown`
        // timing test flake under `./build.sh unit`'s xcodebuild
        // harness even though it had been stable for three consecutive
        // full-suite `swift test` runs beforehand). The CPU time still
        // accrues to this same process (`getpid()`) regardless of which
        // thread burns it, so the measurement is unaffected.
        await Task.detached(priority: .userInitiated) {
            let deadline = Date().addingTimeInterval(1.2)
            var sink: Double = 0
            while Date() < deadline {
                sink += Foundation.sqrt(Double.random(in: 1...100))
            }
            _ = sink
        }.value

        let afterTime = Date()
        let afterMetrics = try ProcessInspector.coreMetrics(pid: getpid()).get()
        content.sampleNowForTesting()

        let cpuPercent = try #require(content.snapshot?.cpuPercent)

        let deltaTicks = (afterMetrics.cpuTicksUser &+ afterMetrics.cpuTicksSystem)
            &- (beforeMetrics.cpuTicksUser &+ beforeMetrics.cpuTicksSystem)
        let deltaSeconds = Double(deltaTicks) * MachTimebase.nanosecondsPerTick / 1_000_000_000
        let wallSeconds = afterTime.timeIntervalSince(beforeTime)
        let expectedPercent = (deltaSeconds / wallSeconds) * 100

        // A 5x band around an independently-computed expectation — wide
        // enough to absorb the small timing skew between these bracketing
        // reads and `ProcessStatusPaneContent`'s own internal sample
        // points, at any contention level, while still catching a ~42x
        // scaling defect outright.
        #expect(
            cpuPercent > expectedPercent / 5,
            "production cpuPercent (\(cpuPercent)) is far below the independently-measured expectation (\(expectedPercent)) from the same raw ticks — looks like a B1-class ticks-as-nanoseconds regression"
        )
        #expect(
            cpuPercent < expectedPercent * 5,
            "production cpuPercent (\(cpuPercent)) is far above the independently-measured expectation (\(expectedPercent)) from the same raw ticks"
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
}
