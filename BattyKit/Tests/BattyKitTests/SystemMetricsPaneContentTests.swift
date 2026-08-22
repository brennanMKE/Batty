// SystemMetricsPaneContentTests.swift

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

    func sampleOnce() -> SystemMetricsSnapshot {
        ledger.recordSample()
        return .empty
    }
}

@MainActor
struct SystemMetricsPaneContentTests {

    private func makeContent(ledger: SamplerLedger) -> SystemMetricsPaneContent {
        let content = SystemMetricsPaneContent()
        content.samplerFactory = { FakeSystemMetricsSampler(ledger: ledger) }
        return content
    }

    @Test func createdHiddenNeverBuildsASamplerOrTicks() {
        let ledger = SamplerLedger()
        let content = makeContent(ledger: ledger)

        content.setUp(visible: false)
        content.performTick()

        #expect(content.lifecyclePhase == .suspended)
        #expect(ledger.createCount == 0)
        #expect(ledger.sampleCallCount == 0)
    }

    @Test func createdVisibleBuildsASamplerAndTicks() {
        let ledger = SamplerLedger()
        let content = makeContent(ledger: ledger)

        content.setUp(visible: true)
        content.performTick()

        #expect(content.lifecyclePhase == .active)
        #expect(ledger.createCount == 1)
        #expect(ledger.sampleCallCount == 1)
    }

    @Test func hidingAnActivePaneStopsTicksImmediately() {
        let ledger = SamplerLedger()
        let content = makeContent(ledger: ledger)

        content.setUp(visible: true)
        content.performTick()
        content.setVisible(false)
        content.performTick()
        content.performTick()

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

    @Test func tearDownFromActiveStopsTicksSynchronously() {
        let ledger = SamplerLedger()
        let content = makeContent(ledger: ledger)

        content.setUp(visible: true)
        content.tearDown()
        content.performTick()

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

    @Test func refreshNowIsANoOpWhileSuspended() {
        let ledger = SamplerLedger()
        let content = makeContent(ledger: ledger)

        content.setUp(visible: false)
        content.refreshNow()

        #expect(ledger.sampleCallCount == 0)
        #expect(content.snapshot == .empty)
    }

    @Test func refreshNowSamplesImmediatelyWhileActive() {
        let ledger = SamplerLedger()
        let content = makeContent(ledger: ledger)

        content.setUp(visible: true)
        content.refreshNow()

        #expect(ledger.sampleCallCount == 1)
    }

    @Test func snapshotStartsEmptyBeforeTheFirstTick() {
        let ledger = SamplerLedger()
        let content = makeContent(ledger: ledger)
        #expect(content.snapshot == .empty)
        #expect(content.lifecyclePhase == .notSetUp)
    }
}
