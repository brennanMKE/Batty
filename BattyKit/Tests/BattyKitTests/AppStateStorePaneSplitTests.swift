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
        let target = session.focusedPaneAnyKind

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
        let target = w2.sessions[0].focusedPaneAnyKind

        let newPaneID = store.splitPane(id: target.id, direction: .vertical)

        #expect(newPaneID != nil)
        #expect(w2.sessions[0].tree.allPanes.contains { $0.id == newPaneID })
    }

    @Test func splitPaneThreadsTheCommandOverrideIntoTheNewPane() {
        let store = AppStateStore()
        let target = store.sessions[0].focusedPaneAnyKind

        let newPaneID = store.splitPane(id: target.id, direction: .horizontal, command: "top")

        let newPane = store.sessions[0].tree.allPanes.first { $0.id == newPaneID }
        #expect(newPane?.tabs[0].terminal.renderedConfig.contains("command = top") == true)
    }

    // MARK: - Pane kind (#0315)

    @Test func splitPaneDefaultsToTerminalKindWhenOmitted() {
        let store = AppStateStore()
        let target = store.sessions[0].focusedPaneAnyKind

        let newPaneID = store.splitPane(id: target.id, direction: .horizontal)

        let newPane = store.sessions[0].tree.allPanes.first { $0.id == newPaneID }
        #expect(newPane?.kind == .terminal)
    }

    @Test func splitPaneThreadsAnExplicitKindIntoTheNewPane() {
        let store = AppStateStore()
        let target = store.sessions[0].focusedPaneAnyKind

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
        let source = store.sessions[0].focusedPaneAnyKind
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
        let source = store.sessions[0].focusedPaneAnyKind

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
        let source = store.sessions[0].focusedPaneAnyKind

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
        let backgroundTarget = background.focusedPaneAnyKind

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
        let backgroundTarget = background.focusedPaneAnyKind
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
        let paneA = session.focusedPaneAnyKind
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

    // MARK: - findUniquePane (`--unique` find-or-create, #0383)

    @Test func findUniquePaneReturnsAVisiblePaneOfTheRequestedKindInTheSameSession() {
        let store = AppStateStore()
        let source = store.sessions[0].focusedPaneAnyKind
        let gitStatusPaneID = store.splitPane(id: source.id, direction: .horizontal, kind: .gitStatus, contentFactory: { _ in nil })

        #expect(store.findUniquePane(paneID: source.id, kind: .gitStatus) == gitStatusPaneID)
    }

    @Test func findUniquePaneReturnsNilWhenNoPaneOfThatKindExistsYet() {
        let store = AppStateStore()
        let source = store.sessions[0].focusedPaneAnyKind

        #expect(store.findUniquePane(paneID: source.id, kind: .gitStatus) == nil)
    }

    /// #0383's pinned match rule: a hidden pane of the same kind does not
    /// satisfy `--unique`.
    @Test func findUniquePaneDoesNotMatchAHiddenPaneOfTheSameKind() {
        let store = AppStateStore()
        let source = store.sessions[0].focusedPaneAnyKind
        let gitStatusPaneID = store.splitPane(id: source.id, direction: .horizontal, kind: .gitStatus, contentFactory: { _ in nil })
        let hiddenPane = store.sessions[0].tree.allPanes.first { $0.id == gitStatusPaneID }
        hiddenPane?.isHidden = true

        #expect(store.findUniquePane(paneID: source.id, kind: .gitStatus) == nil)
    }

    /// Scope is the target Session, not the Window and not the app
    /// (#0383's pinned match rule) — a matching-kind pane in a different
    /// Session must not satisfy the search.
    @Test func findUniquePaneDoesNotMatchAcrossSessions() {
        let store = AppStateStore()
        let background = store.addSession(title: "Background")!
        _ = store.splitPane(id: background.focusedPaneAnyKind.id, direction: .horizontal, kind: .gitStatus, contentFactory: { _ in nil })

        let sourceInFirstSession = store.sessions[0].focusedPaneAnyKind
        #expect(store.findUniquePane(paneID: sourceInFirstSession.id, kind: .gitStatus) == nil)
    }

    @Test func findUniquePaneReturnsNilForAnUnknownPaneID() {
        let store = AppStateStore()
        #expect(store.findUniquePane(paneID: UUID(), kind: .gitStatus) == nil)
    }

    /// `viewOptions` differences (a different `--path`/`--pid`) do not
    /// defeat the match — #0383's pinned scope rule.
    @Test func findUniquePaneMatchesRegardlessOfViewOptions() {
        let store = AppStateStore()
        let source = store.sessions[0].focusedPaneAnyKind
        let processStatusPaneID = store.splitPane(id: source.id, direction: .horizontal, kind: .processStatus, processStatusPid: 4242, contentFactory: { _ in nil })

        #expect(store.findUniquePane(paneID: source.id, kind: .processStatus) == processStatusPaneID)
    }

    /// When more than one visible pane of the kind exists, the same pane is
    /// returned deterministically on every call — #0383's pinned rule
    /// against erroring on duplicates created before `--unique` was used.
    /// #0383's pinned rule: when more than one visible pane of the kind
    /// exists, the match is not merely stable across repeated calls — it is
    /// specifically "the first in the Session's existing Pane ordering"
    /// (issue line 31), i.e. `SplitTree.visiblePanes`' depth-first order.
    /// After the two splits below, that DFS order is `source, second,
    /// first` (each `splitPane` call inserts its new pane as a sibling of
    /// the pane it split, ahead of the previous new pane in a left-to-right
    /// walk) — so the expected match is `second`, not `first`. Asserting
    /// the ordering directly, rather than only "returns *a* match
    /// consistently," is what catches a `.first` → `.last` regression in
    /// `findUniquePane`; a same-input/same-output check alone is invariant
    /// to which element a fixed function of unchanged state prefers.
    @Test func findUniquePaneReturnsTheFirstMatchInTheSessionsDepthFirstOrder() {
        let store = AppStateStore()
        let source = store.sessions[0].focusedPaneAnyKind
        let first = store.splitPane(id: source.id, direction: .horizontal, kind: .gitStatus, contentFactory: { _ in nil })
        let second = store.splitPane(id: source.id, direction: .horizontal, kind: .gitStatus, contentFactory: { _ in nil })

        #expect(store.sessions[0].tree.visiblePanes.map(\.id) == [source.id, second, first])

        let match1 = store.findUniquePane(paneID: source.id, kind: .gitStatus)
        let match2 = store.findUniquePane(paneID: source.id, kind: .gitStatus)

        #expect(match1 == second, "the first git-status pane in the session's DFS pane ordering")
        #expect(match1 == match2)
    }

    /// A pane of a *different* kind never satisfies the search, even when
    /// it is the only other pane in the session.
    @Test func findUniquePaneDoesNotMatchADifferentKind() {
        let store = AppStateStore()
        let source = store.sessions[0].focusedPaneAnyKind
        _ = store.splitPane(id: source.id, direction: .horizontal, kind: .systemMetrics, contentFactory: { _ in nil })

        #expect(store.findUniquePane(paneID: source.id, kind: .gitStatus) == nil)
    }

    /// #0383 review round 1, N4: `findUniquePane` itself guards `kind ==
    /// .terminal` — there is no sensible "the terminal Pane" to find. The
    /// CLI already rejects `--unique` without a non-terminal `--view`
    /// client-side, but the invariant belongs on the function that can
    /// violate it: without this guard, `.terminal` would match the first
    /// visible terminal Pane in the Session — almost always the split's
    /// own source pane — so a caller that bypassed the CLI check would get
    /// back its own pane id instead of ever splitting.
    @Test func findUniquePaneReturnsNilForTerminalKindEvenThoughATerminalPaneExists() {
        let store = AppStateStore()
        let source = store.sessions[0].focusedPaneAnyKind

        #expect(store.findUniquePane(paneID: source.id, kind: .terminal) == nil)
    }

}
