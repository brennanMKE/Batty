// ProcessStatusPaneLifecycleWiringTests.swift

import Foundation
import Testing
@testable import BattyKit

/// Covers the app-level wiring `#0305` adds to `WindowRuntime.hidePane`/
/// `showPane`/`closePane`: a `.processStatus` pane's
/// `ProcessStatusPaneContent` is driven directly from these choke points,
/// not from SwiftUI view teardown (`docs/pane-view-lifecycle.md` §5) —
/// the same "explicit call, not `onDisappear`" shape the terminal path's
/// own `TerminalHostStore` calls already use.
@MainActor
struct ProcessStatusPaneLifecycleWiringTests {

    /// `clock`, when supplied, overrides the production `SystemClock` via
    /// `contentFactory` — the same injectable-cadence seam
    /// `ProcessStatusPaneContentTests` uses directly — so
    /// `aHiddenProcessStatusPaneDoesNotKeepSampling` below can prove "zero
    /// periodic work while suspended" by advancing a `TestClock` explicitly
    /// (`#0428`) instead of paying production's cadence in wall clock.
    /// `contentFactory` is forwarded through `SplitTree.makePane` for
    /// exactly this purpose (see its doc comment): an explicit override
    /// that survives all the way down without being shadowed by the
    /// kind-specific default.
    ///
    /// Left `nil` by default (review round 2, N2) so every other test in
    /// this file still exercises `SplitTree.makePane`'s real `.processStatus`
    /// branch and its `processStatusPid:` argument, rather than
    /// short-circuiting through `contentFactory` just because one test
    /// needs to.
    private func makeProcessStatusPane(
        pinnedTo pid: Int32,
        clock: SchedulingClock? = nil
    ) -> (store: AppStateStore, session: SessionRuntime, paneID: UUID) {
        let store = AppStateStore()
        let session = store.sessions[0]
        let source = session.focusedPaneAnyKind
        var contentFactory: (@MainActor (PaneContentKind) -> (any PaneContentLifecycle)?)?
        if let clock {
            contentFactory = { _ in ProcessStatusPaneContent(target: .pinned(pid), tabLookup: { _ in nil }, clock: clock) }
        }
        let newPaneID = store.splitPane(
            id: source.id,
            direction: .horizontal,
            kind: .processStatus,
            processStatusPid: pid,
            contentFactory: contentFactory
        )!
        return (store, session, newPaneID)
    }

    /// `#0314` merge: `PaneRuntime` now stores the conformer under the
    /// kind-agnostic `content` property (`(any PaneContentLifecycle)?`),
    /// not a `.processStatus`-specific stored property — this casts back
    /// to the concrete type these tests need to read.
    private func processStatusContent(of pane: PaneRuntime) -> ProcessStatusPaneContent? {
        pane.content as? ProcessStatusPaneContent
    }

    @Test func hidingAProcessStatusPaneSuspendsItsSampling() {
        let (store, session, paneID) = makeProcessStatusPane(pinnedTo: Int32(getpid()))
        let pane = session.tree.allPanes.first { $0.id == paneID }!
        #expect(processStatusContent(of: pane)?.lifecyclePhase == .active)

        store.hidePane(id: paneID)

        #expect(pane.isHidden)
        #expect(processStatusContent(of: pane)?.lifecyclePhase == .suspended)
    }

    @Test func showingAHiddenProcessStatusPaneResumesSamplingImmediately() {
        let (store, session, paneID) = makeProcessStatusPane(pinnedTo: Int32(getpid()))
        let pane = session.tree.allPanes.first { $0.id == paneID }!
        store.hidePane(id: paneID)
        #expect(processStatusContent(of: pane)?.lifecyclePhase == .suspended)

        store.showPane(id: paneID)

        #expect(pane.isHidden == false)
        #expect(processStatusContent(of: pane)?.lifecyclePhase == .active)
        #expect(processStatusContent(of: pane)?.snapshot?.pid == getpid())

        // Deterministic cleanup — this test ends with the pane resumed
        // (an active periodic sampling Task), not left to ARC timing
        // (docs/pane-view-lifecycle.md §5's own binding lesson).
        _ = store.closePane(id: paneID)
    }

    @Test func closingAProcessStatusPaneTearsDownItsSampling() {
        let (store, session, paneID) = makeProcessStatusPane(pinnedTo: Int32(getpid()))
        let pane = session.tree.allPanes.first { $0.id == paneID }!
        let content = processStatusContent(of: pane)!
        #expect(content.lifecyclePhase == .active)

        _ = store.closePane(id: paneID)

        #expect(content.lifecyclePhase == .tornDown)
    }

    /// A hidden `.processStatus` pane costs zero periodic work — the
    /// `docs/pane-view-lifecycle.md` §4 guarantee. `hidePane` cancels the
    /// periodic `Task` synchronously, and `TestClock.sleep(for:)` wraps its
    /// continuation in `withTaskCancellationHandler` — so the pending
    /// sleeper is removed and resumed as part of that same `Task.cancel()`
    /// call, before `hidePane` even returns. `pendingCount
    /// == 0` is therefore assertable immediately, synchronously, with no
    /// `await` at all: a real signal (cancellation having already run),
    /// not a hop-based guess. The `advance(by:)` afterward is a second,
    /// belt-and-suspenders check that no *new* sample appears even after
    /// many virtual sampling intervals. Verified (M5) to fail when the
    /// sampler loop's `Task.isCancelled` check and its `lifecyclePhase ==
    /// .active` guard are both removed together — removing only one alone
    /// is still caught by the other, so that's the actual regression this
    /// test needs to catch.
    @Test func aHiddenProcessStatusPaneDoesNotKeepSampling() async {
        let clock = TestClock()
        let (store, session, paneID) = makeProcessStatusPane(pinnedTo: Int32(getpid()), clock: clock)
        let pane = session.tree.allPanes.first { $0.id == paneID }!

        // Real registration signal, not a guess at scheduling order —
        // resumed synchronously the instant the periodic task's first
        // `clock.sleep(for:)` call registers. Otherwise hiding would race
        // an unstarted task instead of a genuinely in-flight one, and the
        // assertions below would pass vacuously regardless of whether
        // cancellation works.
        guard await clock.waitForSleepers(1) else {
            Issue.record("waitForSleepers(1) never reached its threshold")
            return
        }

        store.hidePane(id: paneID)

        #expect(clock.pendingCount == 0, "hiding must cancel the pending sleep synchronously, not just eventually")
        let capturedAtWhenHidden = processStatusContent(of: pane)?.snapshot?.capturedAt

        await clock.advance(by: .seconds(50)) // many sampling intervals (production cadence: 1s)

        #expect(processStatusContent(of: pane)?.snapshot?.capturedAt == capturedAtWhenHidden)
        #expect(clock.pendingCount == 0, "advancing while hidden must not schedule anything new")
    }
}
