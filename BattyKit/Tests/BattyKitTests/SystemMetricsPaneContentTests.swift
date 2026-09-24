// SystemMetricsPaneContentTests.swift

import Foundation
import Testing
@testable import BattyKit

/// Records sampler creation/sampling activity independent of
/// `SystemMetricsPaneContent`'s own lifetime — the same "ledger" pattern
/// `PaneContentLifecycleTests.WatcherLedger` uses, applied to this
/// conformer's real resource: `docs/design/system-metrics-view.md` §4's
/// "discard the sampler (and its delta state) on hide, rebuild fresh on
/// show" contract. `createCount` proves a fresh sampler is built on every
/// `active`-entry; `sampleCallCount` proves sampling only happens while
/// `.active`.
@MainActor
private final class SamplerLedger {
    private(set) var createCount = 0
    private(set) var sampleCallCount = 0

    func recordCreate() { createCount += 1 }
    func recordSample() { sampleCallCount += 1 }
}

@MainActor
private final class FakeSystemMetricsSampler: SystemMetricsSampling {
    let ledger: SamplerLedger

    init(ledger: SamplerLedger) {
        self.ledger = ledger
        ledger.recordCreate()
    }

    func sampleOnce() async -> SystemMetricsSnapshot {
        ledger.recordSample()
        return .empty
    }
}

/// `Thread.isMainThread` itself is unavailable to reference directly from
/// an `async` function (Foundation marks it `NS_SWIFT_UNAVAILABLE_FROM_ASYNC`,
/// guarding against reading thread identity *across* a suspension point) —
/// wrapping the read in a plain, non-async `nonisolated` function sidesteps
/// that without reintroducing the problem it guards against: this call
/// never spans an `await`, so the snapshot it takes is exactly "what thread
/// is executing this line right now," which is what the test needs.
private nonisolated func currentThreadIsMain() -> Bool {
    Thread.isMainThread
}

/// Records which thread `sampleOnce()` actually executed on — the
/// regression pin for #0350: a plain (non-`@MainActor`) `actor` runs its
/// isolated methods on its own executor, never the main thread, so this
/// is a deterministic architectural fact, not a timing race, and needs no
/// sleep/clock assertion to check.
private actor ThreadRecordingSampler: SystemMetricsSampling {
    private(set) var ranOnMainThread: Bool?

    func sampleOnce() async -> SystemMetricsSnapshot {
        ranOnMainThread = currentThreadIsMain()
        return .empty
    }
}

/// A sampler whose `sampleOnce()` suspends until the test explicitly
/// releases it — lets a test deterministically observe "a sample is in
/// flight" (via `waitUntilStarted()`) before driving a hide/teardown, then
/// let the stale sample complete afterward. No sleeps, no polling: both
/// waits are continuation-based, so there's nothing timing-flaky about the
/// ordering this proves.
///
/// **Handles more than one concurrent caller.** `setUp(visible: true)`/
/// `setVisible(true)` both start `SystemMetricsPaneContent`'s own periodic
/// `Task`, whose first iteration calls `sampleOnce()` immediately — so a
/// test that also drives `performTick()` explicitly ends up with *two*
/// in-flight calls against the same gate, not one. A single
/// `CheckedContinuation?` var overwritten by the second caller drops the
/// first continuation unresumed ("SWIFT TASK CONTINUATION MISUSE") and
/// hangs that call's task forever — queuing every pending continuation and
/// resuming all of them together in `release()` fixes that. Every caller
/// captured `generation` before the same hide/teardown/reshow event this
/// gate exists to straddle, so they all reach the same discard-or-apply
/// verdict once released; which one a test happens to `await` doesn't
/// change the outcome it observes.
private actor GatedSampler: SystemMetricsSampling {
    private let result: SystemMetricsSnapshot
    private(set) var callCount = 0
    private var startedContinuations: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuations: [CheckedContinuation<Void, Never>] = []
    private var hasStarted = false

    init(result: SystemMetricsSnapshot) {
        self.result = result
    }

    func sampleOnce() async -> SystemMetricsSnapshot {
        callCount += 1
        hasStarted = true
        let waiters = startedContinuations
        startedContinuations.removeAll()
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { releaseContinuations.append($0) }
        return result
    }

    func waitUntilStarted() async {
        if hasStarted { return }
        await withCheckedContinuation { startedContinuations.append($0) }
    }

    func release() {
        let waiters = releaseContinuations
        releaseContinuations.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

@MainActor
struct SystemMetricsPaneContentTests {

    private func makeContent(ledger: SamplerLedger) -> SystemMetricsPaneContent {
        let content = SystemMetricsPaneContent()
        content.samplerFactory = { FakeSystemMetricsSampler(ledger: ledger) }
        return content
    }

    @Test func createdHiddenNeverBuildsASamplerOrTicks() async {
        let ledger = SamplerLedger()
        let content = makeContent(ledger: ledger)

        content.setUp(visible: false)
        await content.performTick()

        #expect(content.lifecyclePhase == .suspended)
        #expect(ledger.createCount == 0)
        #expect(ledger.sampleCallCount == 0)
    }

    @Test func createdVisibleBuildsASamplerAndTicks() async {
        let ledger = SamplerLedger()
        let content = makeContent(ledger: ledger)

        content.setUp(visible: true)
        await content.performTick()

        #expect(content.lifecyclePhase == .active)
        #expect(ledger.createCount == 1)
        #expect(ledger.sampleCallCount == 1)
    }

    @Test func hidingAnActivePaneStopsTicksImmediately() async {
        let ledger = SamplerLedger()
        let content = makeContent(ledger: ledger)

        content.setUp(visible: true)
        await content.performTick()
        content.setVisible(false)
        await content.performTick()
        await content.performTick()

        #expect(content.lifecyclePhase == .suspended)
        // Only the one tick before hide counted.
        #expect(ledger.sampleCallCount == 1)
    }

    @Test func showingASuspendedPaneBuildsAFreshSamplerAndRefreshesImmediately() {
        let ledger = SamplerLedger()
        let content = makeContent(ledger: ledger)

        content.setUp(visible: false)
        content.setVisible(true)

        #expect(content.lifecyclePhase == .active)
        // setUp(visible: false) never built one; setVisible(true) does.
        #expect(ledger.createCount == 1)
    }

    @Test func hideThenShowDiscardsTheOldSamplerAndBuildsAFreshOne() {
        let ledger = SamplerLedger()
        let content = makeContent(ledger: ledger)

        content.setUp(visible: true)
        content.setVisible(false)
        content.setVisible(true)

        // One sampler for the initial setUp, a second fresh one for the
        // re-show — proving the hidden interval didn't keep the old
        // sampler (and its delta state) alive.
        #expect(ledger.createCount == 2)
    }

    @Test func redundantShowDoesNotRebuildTheSampler() {
        let ledger = SamplerLedger()
        let content = makeContent(ledger: ledger)

        content.setUp(visible: true)
        content.setVisible(true)
        content.setVisible(true)

        #expect(ledger.createCount == 1)
    }

    @Test func tearDownFromActiveStopsTicksSynchronously() async {
        let ledger = SamplerLedger()
        let content = makeContent(ledger: ledger)

        content.setUp(visible: true)
        content.tearDown()
        await content.performTick()

        #expect(content.lifecyclePhase == .tornDown)
        #expect(ledger.sampleCallCount == 0)
    }

    @Test func tearDownIsIdempotent() {
        let ledger = SamplerLedger()
        let content = makeContent(ledger: ledger)

        content.setUp(visible: true)
        content.tearDown()
        content.tearDown()

        #expect(content.lifecyclePhase == .tornDown)
    }

    @Test func refreshNowIsANoOpWhileSuspended() async {
        let ledger = SamplerLedger()
        let content = makeContent(ledger: ledger)

        content.setUp(visible: false)
        await content.refreshNow()

        #expect(ledger.sampleCallCount == 0)
        #expect(content.snapshot == .empty)
    }

    @Test func refreshNowSamplesImmediatelyWhileActive() async {
        let ledger = SamplerLedger()
        let content = makeContent(ledger: ledger)

        content.setUp(visible: true)
        await content.refreshNow()

        #expect(ledger.sampleCallCount == 1)
    }

    @Test func snapshotStartsEmptyBeforeTheFirstTick() {
        let ledger = SamplerLedger()
        let content = makeContent(ledger: ledger)
        #expect(content.snapshot == .empty)
        #expect(content.lifecyclePhase == .notSetUp)
    }

    // MARK: - #0350: off-main-actor sampling

    @Test func sweepRunsOffTheMainActor() async {
        let recorder = ThreadRecordingSampler()
        let content = SystemMetricsPaneContent()
        content.samplerFactory = { recorder }

        content.setUp(visible: true)
        await content.performTick()

        let ranOnMainThread = await recorder.ranOnMainThread
        #expect(ranOnMainThread == false)
    }

    @Test func sampleCompletingAfterHideIsDiscarded() async {
        let nonEmptySnapshot = SystemMetricsSnapshot(
            thermalState: .fair,
            smc: .unavailable,
            cpu: .unavailable,
            memory: .unavailable,
            loadAverage: .zero,
            processes: [],
            sampledAt: Date()
        )
        let gated = GatedSampler(result: nonEmptySnapshot)
        let content = SystemMetricsPaneContent()
        content.samplerFactory = { gated }

        content.setUp(visible: true)
        let tickTask = Task { await content.performTick() }
        await gated.waitUntilStarted()

        // The sample is now suspended mid-flight, inside sampleOnce().
        // Hiding here must both stop future ticks and make sure *this*
        // in-flight one, once released, doesn't overwrite state.
        content.setVisible(false)
        await gated.release()
        await tickTask.value

        #expect(content.lifecyclePhase == .suspended)
        #expect(content.snapshot == .empty)
    }

    @Test func sampleCompletingAfterTearDownIsDiscarded() async {
        let nonEmptySnapshot = SystemMetricsSnapshot(
            thermalState: .fair,
            smc: .unavailable,
            cpu: .unavailable,
            memory: .unavailable,
            loadAverage: .zero,
            processes: [],
            sampledAt: Date()
        )
        let gated = GatedSampler(result: nonEmptySnapshot)
        let content = SystemMetricsPaneContent()
        content.samplerFactory = { gated }

        content.setUp(visible: true)
        let tickTask = Task { await content.performTick() }
        await gated.waitUntilStarted()

        content.tearDown()
        await gated.release()
        await tickTask.value

        #expect(content.lifecyclePhase == .tornDown)
        #expect(content.snapshot == .empty)
    }

    @Test func sampleCompletingAfterHideThenReshowIsDiscardedNotAppliedToTheNewGeneration() async {
        let staleSnapshot = SystemMetricsSnapshot(
            thermalState: .critical,
            smc: .unavailable,
            cpu: .unavailable,
            memory: .unavailable,
            loadAverage: .zero,
            processes: [],
            sampledAt: Date()
        )
        let staleGated = GatedSampler(result: staleSnapshot)
        let freshLedger = SamplerLedger()
        var handedOutStale = false
        let content = SystemMetricsPaneContent()
        content.samplerFactory = {
            if !handedOutStale {
                handedOutStale = true
                return staleGated
            }
            return FakeSystemMetricsSampler(ledger: freshLedger)
        }

        content.setUp(visible: true)
        let tickTask = Task { await content.performTick() }
        await staleGated.waitUntilStarted()

        // Hide (discards the stale sampler) then show again (builds a
        // fresh one and ticks it) before the stale sampler's in-flight
        // sample is released.
        content.setVisible(false)
        content.setVisible(true)
        await staleGated.release()
        await tickTask.value

        // The stale sampler's result must never land, even though the
        // pane is active again by the time it arrives.
        #expect(content.snapshot != staleSnapshot)
        #expect(content.lifecyclePhase == .active)
    }
}
