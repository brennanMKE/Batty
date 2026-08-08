// PaneContentLifecycleTests.swift

import Testing
@testable import BattyKit

/// Pure transition coverage for `PaneLifecycleStateMachine` (#0303) — no
/// object, no resource, just the legal-transition table
/// `docs/pane-view-lifecycle.md` specifies.
@MainActor
struct PaneLifecycleStateMachineTests {

    @Test func startsNotSetUp() {
        let machine = PaneLifecycleStateMachine()
        #expect(machine.phase == .notSetUp)
    }

    @Test func setUpVisibleGoesDirectlyToActive() {
        var machine = PaneLifecycleStateMachine()
        let result = machine.apply(.setUp(visible: true))
        #expect(result == .applied(from: .notSetUp, to: .active))
        #expect(machine.phase == .active)
    }

    @Test func setUpHiddenGoesDirectlyToSuspendedNeverTouchingActive() {
        var machine = PaneLifecycleStateMachine()
        let result = machine.apply(.setUp(visible: false))
        #expect(result == .applied(from: .notSetUp, to: .suspended))
        #expect(machine.phase == .suspended)
    }

    @Test func hideFromActiveSuspends() {
        var machine = PaneLifecycleStateMachine()
        machine.apply(.setUp(visible: true))
        let result = machine.apply(.hide)
        #expect(result == .applied(from: .active, to: .suspended))
        #expect(machine.phase == .suspended)
    }

    @Test func showFromSuspendedActivates() {
        var machine = PaneLifecycleStateMachine()
        machine.apply(.setUp(visible: false))
        let result = machine.apply(.show)
        #expect(result == .applied(from: .suspended, to: .active))
        #expect(machine.phase == .active)
    }

    @Test func showWhileAlreadyActiveIsANoOp() {
        var machine = PaneLifecycleStateMachine()
        machine.apply(.setUp(visible: true))
        let result = machine.apply(.show)
        #expect(result == .noOp(at: .active))
        #expect(machine.phase == .active)
    }

    @Test func hideWhileAlreadySuspendedIsANoOp() {
        var machine = PaneLifecycleStateMachine()
        machine.apply(.setUp(visible: false))
        let result = machine.apply(.hide)
        #expect(result == .noOp(at: .suspended))
        #expect(machine.phase == .suspended)
    }

    @Test(arguments: [true, false])
    func tearDownFromEitherLivePhaseReachesTornDown(startVisible: Bool) {
        var machine = PaneLifecycleStateMachine()
        machine.apply(.setUp(visible: startVisible))
        let expectedFrom: PaneLifecyclePhase = startVisible ? .active : .suspended
        let result = machine.apply(.tearDown)
        #expect(result == .applied(from: expectedFrom, to: .tornDown))
        #expect(machine.phase == .tornDown)
    }

    @Test func tearDownBeforeSetUpIsAllowedAndReachesTornDown() {
        var machine = PaneLifecycleStateMachine()
        let result = machine.apply(.tearDown)
        #expect(result == .applied(from: .notSetUp, to: .tornDown))
        #expect(machine.phase == .tornDown)
    }

    @Test func secondTearDownIsANoOp() {
        var machine = PaneLifecycleStateMachine()
        machine.apply(.setUp(visible: true))
        machine.apply(.tearDown)
        let result = machine.apply(.tearDown)
        #expect(result == .noOp(at: .tornDown))
        #expect(machine.phase == .tornDown)
    }

    @Test(arguments: [PaneLifecycleEvent.setUp(visible: true), .show, .hide])
    func anyNonTeardownEventAfterTornDownIsRejected(event: PaneLifecycleEvent) {
        var machine = PaneLifecycleStateMachine()
        machine.apply(.setUp(visible: true))
        machine.apply(.tearDown)
        let result = machine.apply(event)
        #expect(result == .rejected(at: .tornDown, event: event))
        #expect(machine.phase == .tornDown)
    }

    @Test(arguments: [PaneLifecycleEvent.show, .hide])
    func showOrHideBeforeSetUpIsRejected(event: PaneLifecycleEvent) {
        var machine = PaneLifecycleStateMachine()
        let result = machine.apply(event)
        #expect(result == .rejected(at: .notSetUp, event: event))
        #expect(machine.phase == .notSetUp)
    }

    @Test func doubleSetUpIsRejectedNotSilentlyReapplied() {
        var machine = PaneLifecycleStateMachine()
        machine.apply(.setUp(visible: true))
        let result = machine.apply(.setUp(visible: false))
        #expect(result == .rejected(at: .active, event: .setUp(visible: false)))
        // The rejected re-setUp must not have flipped phase to suspended.
        #expect(machine.phase == .active)
    }
}

/// `PaneLifecycleController` mirrors the pure state machine's behavior
/// while adding the reject-is-logged bookkeeping a `PaneContentLifecycle`
/// conformer is expected to lean on.
@MainActor
struct PaneLifecycleControllerTests {

    @Test func mirrorsStateMachineTransitions() {
        let controller = PaneLifecycleController()
        #expect(controller.phase == .notSetUp)

        #expect(controller.apply(.setUp(visible: false)) == .applied(from: .notSetUp, to: .suspended))
        #expect(controller.apply(.show) == .applied(from: .suspended, to: .active))
        #expect(controller.apply(.hide) == .applied(from: .active, to: .suspended))
        #expect(controller.apply(.tearDown) == .applied(from: .suspended, to: .tornDown))
    }

    @Test func rejectedEventDoesNotChangePhase() {
        let controller = PaneLifecycleController()
        controller.apply(.setUp(visible: true))
        controller.apply(.tearDown)

        let result = controller.apply(.show)
        #expect(result == .rejected(at: .tornDown, event: .show))
        #expect(controller.phase == .tornDown)
    }
}

/// Records live-resource counts for whatever a `RecordingPaneContent`
/// acquires and releases. A separate instance per test (never a shared
/// `static var`) so tests exercising it can run concurrently without
/// interfering with each other.
///
/// Deliberately unclamped: `release()` decrements `liveCount`
/// unconditionally and bumps `releaseCount` on every call, so an
/// over-release (a conformer that releases the same watcher twice instead
/// of guarding its own idempotence) is *visible* — `liveCount` goes
/// negative and `releaseCount` exceeds the number of `acquire()` calls —
/// rather than silently absorbed. A clamped ledger would make exactly the
/// bug this file's idempotence tests exist to catch invisible to them.
private final class WatcherLedger {
    private(set) var liveCount = 0
    private(set) var releaseCount = 0

    func acquire() { liveCount += 1 }

    func release() {
        releaseCount += 1
        liveCount -= 1
    }
}

/// Test double for a non-terminal Pane content kind (#0304/#0305 have no
/// concrete implementation yet — this is what stands in for one). Wraps
/// `PaneLifecycleController` and simulates a watcher/poller as a
/// `WatcherLedger` acquire/release pair instead of a real file watcher or
/// subprocess, and a tick counter that only advances while `.active` —
/// standing in for "periodic work."
///
/// Deliberately: `release()` happens inside `tearDown()`, never inside
/// `deinit`. That is the point being tested — teardown must be observable
/// *synchronously at the call site*, not by waiting to see whether ARC
/// eventually frees something (the #0289 lesson: a log line, or here an
/// eventual `deinit`, claiming release happened is not evidence it
/// happened when the caller needed it to).
@MainActor
private final class RecordingPaneContent: PaneContentLifecycle {
    private let controller = PaneLifecycleController()
    private let ledger: WatcherLedger
    private var watcherAcquired = false

    private(set) var refreshCount = 0
    private(set) var tickCountWhileActive = 0
    private(set) var transitions: [PaneLifecycleTransitionResult] = []

    var lifecyclePhase: PaneLifecyclePhase { controller.phase }

    init(ledger: WatcherLedger) {
        self.ledger = ledger
    }

    func setUp(visible: Bool) {
        transitions.append(controller.apply(.setUp(visible: visible)))
        if visible {
            acquireWatcher()
        }
    }

    func setVisible(_ visible: Bool) {
        let result = controller.apply(visible ? .show : .hide)
        transitions.append(result)
        guard case .applied(_, let to) = result else { return }
        switch to {
        case .active:
            acquireWatcher()
            refreshCount += 1
        case .suspended:
            releaseWatcher()
        case .notSetUp, .tornDown:
            break
        }
    }

    func tearDown() {
        transitions.append(controller.apply(.tearDown))
        releaseWatcher()
    }

    /// Simulates one unit of periodic work (a poll tick, a watcher
    /// firing). Only counts while `.active` — a suspended or torn-down
    /// conformer doing this would be exactly the "hidden view still
    /// costs compute" bug the lifecycle contract exists to prevent.
    func simulateTick() {
        guard lifecyclePhase == .active else { return }
        tickCountWhileActive += 1
    }

    private func acquireWatcher() {
        guard !watcherAcquired else { return }
        watcherAcquired = true
        ledger.acquire()
    }

    private func releaseWatcher() {
        guard watcherAcquired else { return }
        watcherAcquired = false
        ledger.release()
    }
}

/// Exercises `PaneContentLifecycle` end to end against the test double
/// above — the contract is executable, not just documented. There is no
/// real non-terminal view kind yet (#0304/#0305 land later), so this is
/// the correct way to make the lifecycle verifiable now, per #0303's
/// Expected behavior.
@MainActor
struct PaneContentLifecycleTests {

    @Test func createdHiddenNeverAcquiresAWatcherOrTicks() {
        let ledger = WatcherLedger()
        let content = RecordingPaneContent(ledger: ledger)

        content.setUp(visible: false)
        content.simulateTick()
        content.simulateTick()

        #expect(content.lifecyclePhase == .suspended)
        #expect(ledger.liveCount == 0)
        #expect(content.tickCountWhileActive == 0)
    }

    @Test func createdVisibleAcquiresAWatcherAndTicks() {
        let ledger = WatcherLedger()
        let content = RecordingPaneContent(ledger: ledger)

        content.setUp(visible: true)
        content.simulateTick()

        #expect(content.lifecyclePhase == .active)
        #expect(ledger.liveCount == 1)
        #expect(content.tickCountWhileActive == 1)
    }

    @Test func hidingAnActivePaneStopsTicksAndReleasesTheWatcher() {
        let ledger = WatcherLedger()
        let content = RecordingPaneContent(ledger: ledger)

        content.setUp(visible: true)
        content.simulateTick()
        content.setVisible(false)
        content.simulateTick()
        content.simulateTick()

        #expect(content.lifecyclePhase == .suspended)
        #expect(ledger.liveCount == 0)
        // Only the one tick before hide counted — none of the two after.
        #expect(content.tickCountWhileActive == 1)
    }

    @Test func showingASuspendedPaneReacquiresTheWatcherAndRefreshesOnce() {
        let ledger = WatcherLedger()
        let content = RecordingPaneContent(ledger: ledger)

        content.setUp(visible: false)
        content.setVisible(true)

        #expect(content.lifecyclePhase == .active)
        #expect(ledger.liveCount == 1)
        #expect(content.refreshCount == 1)
    }

    @Test func redundantShowDoesNotDoubleAcquireOrDoubleRefresh() {
        let ledger = WatcherLedger()
        let content = RecordingPaneContent(ledger: ledger)

        content.setUp(visible: true)
        content.setVisible(true)
        content.setVisible(true)

        #expect(ledger.liveCount == 1)
        #expect(content.refreshCount == 0)
    }

    @Test func tearDownFromActiveReleasesTheWatcherSynchronously() {
        let ledger = WatcherLedger()
        let content = RecordingPaneContent(ledger: ledger)

        content.setUp(visible: true)
        #expect(ledger.liveCount == 1)

        content.tearDown()

        // Checked immediately after the call returns, on the same line of
        // execution — no delay, no Task, no waiting for `content` itself
        // to deallocate. This is what makes teardown verifiable rather
        // than asserted: the ledger, not `content`'s lifetime, is the
        // evidence.
        #expect(ledger.liveCount == 0)
        #expect(ledger.releaseCount == 1)
        #expect(content.lifecyclePhase == .tornDown)
    }

    @Test func tearDownFromSuspendedIsSafeWithNothingToRelease() {
        let ledger = WatcherLedger()
        let content = RecordingPaneContent(ledger: ledger)

        content.setUp(visible: false)
        content.tearDown()

        #expect(ledger.liveCount == 0)
        // Never shown, so never acquired — tearDown must not call
        // release() on a watcher it never had.
        #expect(ledger.releaseCount == 0)
        #expect(content.lifecyclePhase == .tornDown)
    }

    @Test func tearDownIsIdempotent() {
        let ledger = WatcherLedger()
        let content = RecordingPaneContent(ledger: ledger)

        content.setUp(visible: true)
        content.tearDown()
        content.tearDown()

        #expect(ledger.liveCount == 0)
        // The regression this pins: without RecordingPaneContent's own
        // `watcherAcquired` guard in `releaseWatcher()`, a second
        // `tearDown()` call would release the same watcher twice. A
        // clamped ledger would hide that behind `liveCount == 0` either
        // way (0 - 1 clamped back to 0) — `releaseCount` doesn't clamp,
        // so it catches the double-release directly.
        #expect(ledger.releaseCount == 1)
        #expect(content.lifecyclePhase == .tornDown)
    }

    @Test func tornDownPaneRejectsFurtherVisibilityChangesAndDoesNotReacquire() {
        let ledger = WatcherLedger()
        let content = RecordingPaneContent(ledger: ledger)

        content.setUp(visible: true)
        content.tearDown()
        content.setVisible(true)

        #expect(ledger.liveCount == 0)
        #expect(content.lifecyclePhase == .tornDown)
    }

    @Test func fullCycleRecordsExactlyTheExpectedTransitionSequence() {
        let ledger = WatcherLedger()
        let content = RecordingPaneContent(ledger: ledger)

        content.setUp(visible: false)
        content.setVisible(true)
        content.setVisible(false)
        content.tearDown()

        #expect(content.transitions == [
            .applied(from: .notSetUp, to: .suspended),
            .applied(from: .suspended, to: .active),
            .applied(from: .active, to: .suspended),
            .applied(from: .suspended, to: .tornDown),
        ])
    }
}
