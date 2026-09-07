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

    /// `samplingInterval`, when supplied, overrides the production 1s
    /// sampling cadence via `contentFactory` — the same injectable-cadence
    /// seam `ProcessStatusPaneContentTests` uses directly — so
    /// `aHiddenProcessStatusPaneDoesNotKeepSampling` below can prove "zero
    /// periodic work while suspended" across several real cadences without
    /// paying production's cadence in wall clock. `contentFactory` is
    /// forwarded through `SplitTree.makePane` for exactly this purpose
    /// (see its doc comment): an explicit override that survives all the
    /// way down without being shadowed by the kind-specific default.
    ///
    /// Left `nil` by default (review round 2, N2) so every other test in
    /// this file still exercises `SplitTree.makePane`'s real `.processStatus`
    /// branch and its `processStatusPid:` argument, rather than
    /// short-circuiting through `contentFactory` just because one test
    /// needs to.
    private func makeProcessStatusPane(
        pinnedTo pid: Int32,
        samplingInterval: Duration? = nil
    ) -> (store: AppStateStore, session: SessionRuntime, paneID: UUID) {
        let store = AppStateStore()
        let session = store.sessions[0]
        let source = session.focusedPaneAnyKind
        var contentFactory: (@MainActor (PaneContentKind) -> (any PaneContentLifecycle)?)?
        if let samplingInterval {
            contentFactory = { _ in ProcessStatusPaneContent(target: .pinned(pid), samplingInterval: samplingInterval) }
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
    /// `docs/pane-view-lifecycle.md` §4 guarantee, checked the same way
    /// `ProcessStatusPaneContentTests` checks it: real wall-clock time
    /// passes and the snapshot does not change while suspended. The
    /// `contentFactory` override in `makeProcessStatusPane` gives this a
    /// 20ms cadence, so a wait spanning many real cadences (still a
    /// genuine "did anything happen" window) costs 200ms here instead of
    /// production's 1s-cadence multiple.
    @Test func aHiddenProcessStatusPaneDoesNotKeepSampling() async throws {
        let (store, session, paneID) = makeProcessStatusPane(pinnedTo: Int32(getpid()), samplingInterval: .milliseconds(20))
        let pane = session.tree.allPanes.first { $0.id == paneID }!
        store.hidePane(id: paneID)
        let capturedAtWhenHidden = processStatusContent(of: pane)?.snapshot?.capturedAt

        try await Task.sleep(for: .milliseconds(200))

        #expect(processStatusContent(of: pane)?.snapshot?.capturedAt == capturedAtWhenHidden)
    }
}
