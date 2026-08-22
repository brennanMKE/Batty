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

    private func makeProcessStatusPane(pinnedTo pid: Int32) -> (store: AppStateStore, session: SessionRuntime, paneID: UUID) {
        let store = AppStateStore()
        let session = store.sessions[0]
        let source = session.focusedPane
        let newPaneID = store.splitPane(id: source.id, direction: .horizontal, kind: .processStatus, processStatusPid: pid)!
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
        // (an active 1s sampling Task), not left to ARC timing
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
    /// passes and the snapshot does not change while suspended.
    @Test func aHiddenProcessStatusPaneDoesNotKeepSampling() async throws {
        let (store, session, paneID) = makeProcessStatusPane(pinnedTo: Int32(getpid()))
        let pane = session.tree.allPanes.first { $0.id == paneID }!
        store.hidePane(id: paneID)
        let capturedAtWhenHidden = processStatusContent(of: pane)?.snapshot?.capturedAt

        try await Task.sleep(for: .seconds(1.2))

        #expect(processStatusContent(of: pane)?.snapshot?.capturedAt == capturedAtWhenHidden)
    }
}
