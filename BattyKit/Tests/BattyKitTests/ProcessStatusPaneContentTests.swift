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
@MainActor
struct ProcessStatusPaneContentTests {

    /// Polls instead of trusting a single fixed sleep — this suite runs
    /// alongside ~1100 other tests, several of which spawn real
    /// subprocesses and block synchronously (`Process.waitUntilExit()`),
    /// which can starve the cooperative thread pool and delay a `Task`'s
    /// resumption well past its nominal `Task.sleep` duration. A generous
    /// polling budget tolerates that scheduling jitter without weakening
    /// what's actually being asserted (a real state change did happen).
    private func waitUntil(timeout: Duration = .seconds(15), _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    // MARK: - No selection

    @Test func noTargetStartsAndStaysNoSelection() {
        let content = ProcessStatusPaneContent(target: nil)
        #expect(content.hasNoSelection)
        content.setUp(visible: true)
        #expect(content.hasNoSelection)
        #expect(content.lifecyclePhase == .active)
        #expect(content.snapshot == nil)
    }

    // MARK: - Pinned mode: setUp/setVisible/tearDown transitions

    @Test func setUpVisibleSamplesImmediatelyForAPinnedTarget() {
        let content = ProcessStatusPaneContent(target: .pinned(getpid()))
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
        let content = ProcessStatusPaneContent(target: .pinned(getpid()))
        content.setUp(visible: false)
        #expect(content.lifecyclePhase == .suspended)
        #expect(content.snapshot == nil)
    }

    @Test func showingASuspendedPaneSamplesImmediately() {
        let content = ProcessStatusPaneContent(target: .pinned(getpid()))
        content.setUp(visible: false)
        content.setVisible(true)
        #expect(content.lifecyclePhase == .active)
        #expect(content.snapshot?.pid == getpid())
    }

    @Test func tearDownIsIdempotentAndTerminal() {
        let content = ProcessStatusPaneContent(target: .pinned(getpid()))
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
    /// wall-clock time pass across the 1-second cadence rather than
    /// trusting that `setVisible` was called.
    @Test func samplingStopsWhileSuspendedAndResumesWhenShown() async throws {
        let content = ProcessStatusPaneContent(target: .pinned(getpid()))
        content.setUp(visible: true)
        let firstCapture = try #require(content.snapshot?.capturedAt)

        await waitUntil { (content.snapshot?.capturedAt ?? firstCapture) > firstCapture }
        let secondCapture = try #require(content.snapshot?.capturedAt)
        #expect(secondCapture > firstCapture)

        content.setVisible(false)
        let capturedAtHideTime = content.snapshot?.capturedAt

        // A real wait, comfortably longer than the 1s cadence — this
        // assertion is timing-safe regardless of scheduler delay: once
        // `setVisible(false)` cancels the sampling `Task`, any already
        // in-flight continuation still observes `Task.isCancelled` before
        // it would sample again (both run on this package's MainActor
        // isolation, so there is no window where the cancel and a
        // not-yet-cancelled sample interleave).
        try await Task.sleep(for: .seconds(1.5))
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
        let content = ProcessStatusPaneContent(target: .pinned(1)) // launchd
        content.setUp(visible: true)
        #expect(content.runState == .permissionDenied)
        #expect(content.snapshot?.executablePath != nil)
        #expect(content.snapshot?.name == "launchd")
        #expect(content.snapshot?.commandLine == nil)
        #expect(content.snapshot?.cpuPercent == nil)
    }

    // MARK: - Exited / tombstone state (§3.6), pinned mode

    @Test func pinnedTargetTombstonesOnExitAndStopsSampling() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["0.05"]
        try process.run()
        let pid = process.processIdentifier
        process.waitUntilExit()

        let content = ProcessStatusPaneContent(target: .pinned(pid))
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
        let content = ProcessStatusPaneContent(target: nil)
        content.setUp(visible: true)
        #expect(content.hasNoSelection)

        content.retarget(to: .pinned(getpid()))
        #expect(content.hasNoSelection == false)
        #expect(content.snapshot?.pid == getpid())
        #expect(content.lifecyclePhase == .active)
    }

    @Test func retargetWhileSuspendedDoesNotSampleUntilShown() {
        let content = ProcessStatusPaneContent(target: nil)
        content.setUp(visible: false)
        content.retarget(to: .pinned(getpid()))
        #expect(content.lifecyclePhase == .suspended)
        #expect(content.snapshot == nil)
    }

    @Test func watchInsteadPinsToTheGivenChildPid() {
        let content = ProcessStatusPaneContent(target: .pinned(1))
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
    @Test func cpuPercentReflectsSubstantialRealCoreUsage() async {
        let content = ProcessStatusPaneContent(target: .pinned(getpid()))
        content.setUp(visible: true) // establishes the CPU baseline; cpuPercent is nil on this first sample

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

        content.sampleNowForTesting()

        let cpuPercent = content.snapshot?.cpuPercent
        #expect(cpuPercent != nil)
        // A generous floor, deliberately not "close to 100%": this suite
        // runs alongside ~1100 other tests (and, per this project's own
        // build docs, potentially sibling agents building concurrently),
        // so this process may not get a full core's worth of wall-clock
        // time even while genuinely busy-looping — measured as low as
        // ~39% under real contention while developing this test. The
        // threshold only needs to sit well clear of what B1's bug would
        // have produced (raw mach ticks treated as nanoseconds under-
        // reports by ~42x — roughly 1-2% for a fully busy core), not
        // assert an uncontended-machine number.
        #expect((cpuPercent ?? 0) > 10, "expected substantial CPU usage from a real busy loop, got \(String(describing: cpuPercent))% — this is far below what a genuinely busy core reports even under heavy contention, and squarely in the range B1's raw-ticks-as-nanoseconds bug would have produced")
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
        let content = ProcessStatusPaneContent(target: .pinned(getpid()))

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

        let content = ProcessStatusPaneContent(target: .pinned(pid))
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

        let content = ProcessStatusPaneContent(target: .pinned(pid))
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

    // MARK: - The sampling Task is actually gone, not just "phase says so"
    // (review round 1's general test-gap finding)

    @Test func hidingActuallyCancelsTheSamplingTaskNotJustTheObservablePhase() {
        let content = ProcessStatusPaneContent(target: .pinned(getpid()))
        content.setUp(visible: true)
        #expect(content.isSamplingTaskAlive)

        content.setVisible(false)
        #expect(content.isSamplingTaskAlive == false, "review round 1: removing stopSampling() from the hide path left the equivalent behavioral test passing anyway, because the loop's own lifecyclePhase guard alone was enough — this checks the Task reference directly")
    }

    @Test func tearDownActuallyCancelsTheSamplingTask() {
        let content = ProcessStatusPaneContent(target: .pinned(getpid()))
        content.setUp(visible: true)
        #expect(content.isSamplingTaskAlive)

        content.tearDown()
        #expect(content.isSamplingTaskAlive == false)
    }
}
