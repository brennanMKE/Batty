// AppStateStorePaneSplitTests.swift

import Foundation
import Testing
@testable import BattyKit

/// Covers `AppStateStore.splitPane(id:direction:command:)` and
/// `.focusedPaneIDFallback()` — the app-side source of the `paneSplit` XPC
/// verb (#0282), the first mutating verb this transport carries.
@MainActor
struct AppStateStorePaneSplitTests {

    @Test func splitPaneOnTheSelectedSessionReturnsTheNewPaneID() {
        let store = AppStateStore()
        let session = store.sessions[0]
        let target = session.focusedPane

        let newPaneID = store.splitPane(id: target.id, direction: .horizontal)

        #expect(newPaneID != nil)
        #expect(session.tree.allPanes.contains { $0.id == newPaneID })
    }

    @Test func splitPaneReturnsNilForAnUnknownPaneID() {
        let store = AppStateStore()
        #expect(store.splitPane(id: UUID(), direction: .horizontal) == nil)
    }

    @Test func splitPaneResolvesAPaneInANonKeyWindow() {
        let store = AppStateStore()
        let w2 = store.windowRuntime(for: WindowID())
        let target = w2.sessions[0].focusedPane

        let newPaneID = store.splitPane(id: target.id, direction: .vertical)

        #expect(newPaneID != nil)
        #expect(w2.sessions[0].tree.allPanes.contains { $0.id == newPaneID })
    }

    @Test func splitPaneThreadsTheCommandOverrideIntoTheNewPane() {
        let store = AppStateStore()
        let target = store.sessions[0].focusedPane

        let newPaneID = store.splitPane(id: target.id, direction: .horizontal, command: "top")

        let newPane = store.sessions[0].tree.allPanes.first { $0.id == newPaneID }
        #expect(newPane?.tabs[0].terminal.renderedConfig.contains("command = top") == true)
    }

    // MARK: - Pane kind (#0315)

    @Test func splitPaneDefaultsToTerminalKindWhenOmitted() {
        let store = AppStateStore()
        let target = store.sessions[0].focusedPane

        let newPaneID = store.splitPane(id: target.id, direction: .horizontal)

        let newPane = store.sessions[0].tree.allPanes.first { $0.id == newPaneID }
        #expect(newPane?.kind == .terminal)
    }

    @Test func splitPaneThreadsAnExplicitKindIntoTheNewPane() {
        let store = AppStateStore()
        let target = store.sessions[0].focusedPane

        // contentFactory: { _ in nil } — this test is only about the kind
        // field surviving the split, not about content behavior. Without
        // it, `.lmStudioDashboard`'s real conformer would `setUp()` a real
        // subprocess/HTTP poll as a side effect of this unrelated test
        // (review round 1, post-#0314-rebase: `splitPane`'s default
        // factory now constructs the real `LMStudioDashboardPaneContent`).
        let newPaneID = store.splitPane(id: target.id, direction: .horizontal, kind: .lmStudioDashboard, contentFactory: { _ in nil })

        let newPane = store.sessions[0].tree.allPanes.first { $0.id == newPaneID }
        #expect(newPane?.kind == .lmStudioDashboard)
    }

    // MARK: - #0305's `.processStatus` kind: mode selection at creation

    /// Mode B (the default): no `--pid` means the new pane follows the
    /// split-source pane's active Tab (`docs/design/process-status-view.md`
    /// §2's "previously-focused Pane's active Tab").
    @Test func splitPaneWithProcessStatusKindDefaultsToFollowingTheSourcePanesActiveTab() {
        let store = AppStateStore()
        let source = store.sessions[0].focusedPane
        let sourceTabID = source.activeTabID

        let newPaneID = store.splitPane(id: source.id, direction: .horizontal, kind: .processStatus)

        let newPane = store.sessions[0].tree.allPanes.first { $0.id == newPaneID }
        #expect(newPane?.kind == .processStatus)
        #expect((newPane?.content as? ProcessStatusPaneContent)?.target == .followingTab(sourceTabID))

        // Deterministic cleanup, not left to ARC timing (docs/pane-view-
        // lifecycle.md §5's own binding lesson) — this test needs the real
        // conformer to assert `.target`, so it must tear it down explicitly
        // rather than leak its 1s sampling Task for the rest of this test
        // process (review round 3, post-#0313-rebase: #0313's own reviewer
        // found exactly this leak class at three other call sites).
        if let newPaneID { _ = store.closePane(id: newPaneID) }
    }

    /// Mode A: an explicit `--pid` pins the new pane instead.
    @Test func splitPaneWithProcessStatusKindAndAnExplicitPidPinsToThatPid() {
        let store = AppStateStore()
        let source = store.sessions[0].focusedPane

        let newPaneID = store.splitPane(id: source.id, direction: .horizontal, kind: .processStatus, processStatusPid: 4242)

        let newPane = store.sessions[0].tree.allPanes.first { $0.id == newPaneID }
        #expect((newPane?.content as? ProcessStatusPaneContent)?.target == .pinned(4242))

        // Deterministic cleanup — see the comment above.
        if let newPaneID { _ = store.closePane(id: newPaneID) }
    }

    /// The new pane's `ProcessStatusPaneContent` can look up tabs across
    /// the whole tree by id (`docs/design/process-status-view.md` §2's
    /// by-id lookup, not a strong `TabRuntime` reference) — verified here
    /// via the mode-B target resolving a real sample once made visible.
    @Test func processStatusPaneCanResolveTheSourceTabsForegroundPidThroughTheTree() {
        let store = AppStateStore()
        let source = store.sessions[0].focusedPane

        let newPaneID = store.splitPane(id: source.id, direction: .horizontal, kind: .processStatus)
        let newPane = store.sessions[0].tree.allPanes.first { $0.id == newPaneID }

        // No AppKit surface is ever attached in this headless test, so
        // `foregroundPid` is nil and the tick reports "no selection" —
        // this asserts the tab *lookup* succeeded (not a tombstone), which
        // is the thing this test is actually about.
        let newProcessStatusContent = newPane?.content as? ProcessStatusPaneContent
        #expect(newProcessStatusContent?.hasNoSelection == true)
        guard case .running = newProcessStatusContent?.runState else {
            Issue.record("expected .running (a successful, if empty, lookup), not a tombstone")
            if let newPaneID { _ = store.closePane(id: newPaneID) }
            return
        }

        // Deterministic cleanup — see the comment above.
        if let newPaneID { _ = store.closePane(id: newPaneID) }
    }

    // MARK: - Background-session mutation must not steal focus or switch
    // the active session (#0257, binding doubly for the first mutation)

    @Test func splitOfABackgroundSessionDoesNotChangeSelectionOrTheForegroundSessionsFocus() {
        let store = AppStateStore()
        let selected = store.sessions[0]
        let background = store.addSession(title: "Background")!
        store.windows[0].selectedSessionID = selected.id

        let selectedFocusedPaneBefore = selected.tree.focusedPaneID
        let selectedSessionIDBefore = store.windows[0].selectedSessionID
        let backgroundTarget = background.focusedPane

        let newPaneID = store.splitPane(id: backgroundTarget.id, direction: .horizontal)

        #expect(newPaneID != nil)
        #expect(store.windows[0].selectedSessionID == selectedSessionIDBefore,
                "splitting a background session must not change the window's selected session")
        #expect(selected.tree.focusedPaneID == selectedFocusedPaneBefore,
                "splitting a background session must not change the foreground session's focus")
        #expect(background.tree.allPanes.contains { $0.id == newPaneID },
                "the new pane must land in the background session's own tree")
    }

    /// The background session's *own* tree focus decision: splitting its
    /// currently-focused pane moves that tree's focus to the new pane
    /// (mirrors `splitFocusedPane`'s existing UI behavior) — but this is
    /// entirely local to the background session's tree and never surfaces
    /// as the app's selected session or key window.
    @Test func splitOfABackgroundSessionsFocusedPaneMovesThatSessionsOwnFocus() {
        let store = AppStateStore()
        let selected = store.sessions[0]
        let background = store.addSession(title: "Background")!
        store.windows[0].selectedSessionID = selected.id
        let backgroundTarget = background.focusedPane
        #expect(background.tree.focusedPaneID == backgroundTarget.id)

        let newPaneID = store.splitPane(id: backgroundTarget.id, direction: .horizontal)

        #expect(background.tree.focusedPaneID == newPaneID)
        #expect(store.windows[0].selectedSessionID == selected.id,
                "the background session's own focus move must not select it")
    }

    /// Splitting a pane that is explicitly named but is *not* its session's
    /// focused pane (background or foreground) must leave that session's
    /// focus exactly where it was.
    @Test func splitOfANonFocusedPaneInTheSelectedSessionLeavesFocusUnchanged() {
        let store = AppStateStore()
        let session = store.sessions[0]
        let paneA = session.focusedPane
        let paneB = session.tree.splitFocusedPane(direction: .horizontal)
        session.tree.focusedPaneID = paneB.id

        let newPaneID = store.splitPane(id: paneA.id, direction: .vertical)

        #expect(newPaneID != nil)
        #expect(session.tree.focusedPaneID == paneB.id,
                "targeting a non-focused pane must not move this session's focus")
    }

    // MARK: - focusedPaneIDFallback()

    @Test func focusedPaneIDFallbackResolvesTheSelectedSessionsFocusedPane() {
        let store = AppStateStore()
        let session = store.sessions[0]
        let paneB = session.tree.splitFocusedPane(direction: .horizontal)
        session.tree.focusedPaneID = paneB.id

        #expect(store.focusedPaneIDFallback() == paneB.id)
    }

    @Test func focusedPaneIDFallbackFollowsSelectedSessionNotJustTheFirstOne() {
        let store = AppStateStore()
        let second = store.addSession(title: "Second")!
        store.windows[0].selectedSessionID = second.id

        #expect(store.focusedPaneIDFallback() == second.tree.focusedPaneID)
        #expect(store.focusedPaneIDFallback() != store.sessions[0].tree.focusedPaneID)
    }
}
