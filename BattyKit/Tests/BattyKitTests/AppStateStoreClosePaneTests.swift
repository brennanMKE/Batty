// AppStateStoreClosePaneTests.swift

import Foundation
import Testing
@testable import BattyKit

/// Covers `AppStateStore.closePane(id:)` / `WindowRuntime.closePane(id:
/// refuseIfAppsLastPane:)` — #0283's XPC `pane close` verb. Distinct from
/// `closeTab` (`CloseTabCascadeTests.swift`): this always ends *every*
/// Tab's Terminal Session in the target pane, not just the active one — the
/// property that separates `pane close` from `tab close`.
@MainActor
struct AppStateStoreClosePaneTests {

    // MARK: - Pane-level semantic: every tab ends, not just the active one

    /// `TerminalHostStore.releaseTerminalView` early-returns headlessly with
    /// no registered view, so it can't be asserted directly in a unit test.
    /// Bell-feed cleanup (`cleanUpBellState(forTabIDs:)`, driven off the same
    /// `tabIDs` set) is the assertable proxy: ringing a bell on every tab
    /// (including the two inactive ones) and then requiring every one of
    /// those entries to be gone is a property that a teardown loop touching
    /// only the active tab could not satisfy — unlike asserting pane/tab
    /// counts alone, which pass identically whether one tab or three were
    /// torn down.
    @Test func closingAPaneWithMultipleTabsEndsEveryTabsTerminalSession() async {
        let store = AppStateStore()
        let session = store.sessions[0]
        let originalPane = session.tree.allPanes[0]
        let sibling = session.tree.splitFocusedPane(direction: .horizontal)
        session.tree.focusedPaneID = originalPane.id
        originalPane.addTab()
        originalPane.addTab()
        let tabIDs = originalPane.tabs.map(\.id)
        #expect(tabIDs.count == 3, "precondition: multiple tabs, only one of them active")

        for tabID in tabIDs {
            let tab = originalPane.tabs.first { $0.id == tabID }!
            tab.terminal.terminalDidRingBell()
            await awaitTerminalStatePublish { tab.terminal.bellCount > 0 }
            store.recordBellTick(forTabID: tabID)
        }
        #expect(store.bellFeed.entries.count == 3, "precondition: every tab has a live bell-feed entry")

        let outcome = store.closePane(id: originalPane.id)

        #expect(outcome == .closed)
        #expect(!session.tree.allPanes.contains { $0.id == originalPane.id })
        #expect(session.tree.allPanes.count == 1)
        #expect(session.tree.allPanes[0].id == sibling.id)
        for tabID in tabIDs {
            #expect(store.bellFeed.entries.contains { $0.tabID == tabID } == false,
                    "tab \(tabID) must have its Terminal Session ended, not just the active one")
        }
        #expect(store.bellFeed.entries.isEmpty)
        #expect(session.unseenBellCount == 0)
    }

    @Test func closingAPaneReturnsUnknownForAStaleID() {
        let store = AppStateStore()
        #expect(store.closePane(id: UUID()) == .unknownPane)
    }

    // MARK: - Sibling takes over the freed space (split tree rebalancing)

    @Test func closingAPaneCollapsesTheSplitSoTheSiblingTakesTheFullSpace() {
        let store = AppStateStore()
        let session = store.sessions[0]
        let paneA = session.tree.allPanes[0]
        let paneB = session.tree.splitFocusedPane(direction: .horizontal)
        #expect(session.tree.panePositions[paneA.id]?.label == "1/1")
        #expect(session.tree.panePositions[paneB.id]?.label == "2/1")

        let outcome = store.closePane(id: paneA.id)

        #expect(outcome == .closed)
        #expect(session.tree.allPanes.count == 1)
        #expect(session.tree.panePositions[paneB.id]?.label == "1/1",
                "paneB must absorb paneA's freed slot, not stay parked at 2/1")
        guard case .leaf(let onlyPane) = session.tree.root else {
            Issue.record("expected the tree to collapse to a single leaf")
            return
        }
        #expect(onlyPane.id == paneB.id)
    }

    // MARK: - Focus after close (#0283's own decision, distinct from #0282's
    // split-focus policy)

    /// #0337's centerpiece — the issue's own repro steps, verbatim: three
    /// temporary Panes (A, B, C) split off Main and clicked into in order,
    /// closing the focused Pane three times in a row walks focus back
    /// C -> B -> A -> Main.
    ///
    /// **This alone does not prove recency is doing the work.** Each split
    /// here nests inside the previously-focused Pane (Cmd-D three times in
    /// a row), so C's structural sibling *is* B and B's structural sibling
    /// *is* A — the `#0021` sibling-subtree fallback (`SplitTreeNode
    /// .siblingSubtree`, used when no history is available) would answer
    /// exactly the same walk-back with the recency stack deleted entirely.
    /// Confirmed by mutation: disabling the history branch in
    /// `SplitTree.resolveSuccessor` left this test green. The test that
    /// actually isolates recency from sibling-adjacency is
    /// `closingFallsBackToTheMostRecentlyFocusedPaneEvenWhenItIsNotTheStructuralSibling`
    /// below — kept as a separate test because this one still guards the
    /// literal acceptance-criteria wording and the "not Main both times"
    /// property no positional fallback satisfies.
    @Test func closingThreeSequentialPanesWalksFocusBackByRecencyNotPosition() {
        let store = AppStateStore()
        let session = store.sessions[0]
        let main = session.tree.allPanes[0]
        let paneA = session.tree.splitFocusedPane(direction: .horizontal)
        let paneB = session.tree.splitFocusedPane(direction: .horizontal)
        let paneC = session.tree.splitFocusedPane(direction: .horizontal)
        // Click into A, then B, then C — independent of whichever Pane the
        // splits themselves happened to leave focused — so history reads
        // C -> B -> A -> Main, per the issue's own repro steps.
        session.tree.focusedPaneID = paneA.id
        session.tree.focusedPaneID = paneB.id
        session.tree.focusedPaneID = paneC.id
        #expect(session.tree.allPanes.count == 4)

        #expect(store.closePane(id: paneC.id) == .closed)
        #expect(session.tree.focusedPaneID == paneB.id,
                "closing C must focus B, the most recently focused survivor — not Main, the leftmost leaf")

        #expect(store.closePane(id: paneB.id) == .closed)
        #expect(session.tree.focusedPaneID == paneA.id,
                "closing B must focus A next, matching the recorded recency order, not Main again")

        #expect(store.closePane(id: paneA.id) == .closed)
        #expect(session.tree.focusedPaneID == main.id,
                "only Main survives at this point, so recency and position necessarily agree here")
    }

    /// The test that actually isolates recency from sibling-adjacency
    /// (see the comment above): builds a tree where the Pane about to close
    /// has a structural sibling that is a *different* Pane than the one
    /// most recently focused before it, so a sibling-only fallback and a
    /// true recency stack disagree.
    ///
    /// Shape: `split(H, split(V, Main, Other), Focused)` — `Other` is
    /// spliced in next to Main via `splitPane(id:)` while Focused (not
    /// Main) holds focus, so `Other` is never itself focused
    /// (`SplitTree.splitPane`'s "Focus decision" doc comment: focus only
    /// transfers when the split target was already focused). Clicking
    /// `Other` then back onto `Focused` makes `Other` the most recently
    /// focused survivor without ever making it Focused's structural
    /// sibling — Focused's actual sibling is the whole `split(V, Main,
    /// Other)` subtree, whose own first (structural) leaf is Main, not
    /// Other. A sibling-only fallback would therefore answer Main; the
    /// recency stack must answer Other.
    @Test func closingFallsBackToTheMostRecentlyFocusedPaneEvenWhenItIsNotTheStructuralSibling() {
        let store = AppStateStore()
        let session = store.sessions[0]
        let main = session.tree.allPanes[0]
        let focused = session.tree.splitFocusedPane(direction: .horizontal)
        let other = session.tree.splitPane(id: main.id, direction: .vertical)!
        #expect(session.tree.focusedPaneID == focused.id, "precondition: splitPane(id: main) must not steal focus from Focused")

        session.tree.focusedPaneID = other.id
        session.tree.focusedPaneID = focused.id

        #expect(store.closePane(id: focused.id) == .closed)

        #expect(session.tree.focusedPaneID == other.id,
                "the most recently focused survivor is `other`, not `main` — a sibling-subtree-only fallback would wrongly answer `main`, other's structural sibling within Focused's absorbed space")
    }

    /// A dedicated three-Pane version of "closing a non-focused Pane leaves
    /// focus untouched" — guards against a regression where introducing the
    /// recency stack accidentally reassigns focus on every close instead of
    /// only when the closed Pane was the focused one.
    @Test func closingANonFocusedPaneAmongThreeSurvivorsLeavesFocusUnchanged() {
        let store = AppStateStore()
        let session = store.sessions[0]
        _ = session.tree.allPanes[0]
        let paneA = session.tree.splitFocusedPane(direction: .horizontal)
        let paneB = session.tree.splitFocusedPane(direction: .horizontal)
        session.tree.focusedPaneID = paneA.id

        #expect(store.closePane(id: paneB.id) == .closed)

        #expect(session.tree.focusedPaneID == paneA.id,
                "closing a Pane that wasn't focused must never disturb focus, even with a populated recency stack")
    }

    @Test func closingTheFocusedPaneMovesFocusToTheRemainingSibling() {
        let store = AppStateStore()
        let session = store.sessions[0]
        let paneA = session.tree.allPanes[0]
        let paneB = session.tree.splitFocusedPane(direction: .horizontal)
        session.tree.focusedPaneID = paneA.id

        store.closePane(id: paneA.id)

        #expect(session.tree.focusedPaneID == paneB.id,
                "the containing session's focusedPaneID must not dangle on the removed pane")
    }

    @Test func closingANonFocusedPaneLeavesFocusUnchanged() {
        let store = AppStateStore()
        let session = store.sessions[0]
        let paneA = session.tree.allPanes[0]
        let paneB = session.tree.splitFocusedPane(direction: .horizontal)
        session.tree.focusedPaneID = paneB.id

        store.closePane(id: paneA.id)

        #expect(session.tree.focusedPaneID == paneB.id)
    }

    // MARK: - #0256's hidden-pane invariants: "never leave focus on a hidden
    // pane" and "a session must always have ≥1 visible pane," explicitly
    // bound against the pane-collapse-on-close path

    @Test func closingTheVisibleFocusedPaneUnhidesTheHiddenSiblingThatAbsorbsItsSpace() {
        let store = AppStateStore()
        let session = store.sessions[0]
        let paneA = session.tree.allPanes[0]
        let paneB = session.tree.splitFocusedPane(direction: .horizontal)
        session.tree.focusedPaneID = paneA.id
        store.windows[0].hidePane(id: paneB.id)
        #expect(paneB.isHidden)
        #expect(session.tree.visiblePanes.map(\.id) == [paneA.id])

        let outcome = store.closePane(id: paneA.id)

        #expect(outcome == .closed)
        #expect(session.tree.allPanes.count == 1)
        #expect(!paneB.isHidden,
                "paneB inherited paneA's space; leaving it hidden would render the session blank")
        #expect(!session.tree.visiblePanes.isEmpty, "a session must always have ≥1 visible pane (#0256)")
        #expect(session.tree.focusedPaneID == paneB.id)
        #expect(!(session.tree.allPanes.first { $0.id == session.tree.focusedPaneID }?.isHidden ?? true),
                "focus must never sit on a hidden pane (#0256)")
    }

    /// Round-2 review regression: `visiblePanes.isEmpty` alone under-covers
    /// #0256's "never leave focus on a hidden pane" rule. Tree shape
    /// `split(A, split(B, C))` with A hidden, B visible and focused, C
    /// visible: closing B collapses the right subtree to
    /// `split(A, C)`, and since `focusedPaneID == B` no longer exists,
    /// `SplitTree.removePane`'s fallback reassigns it to
    /// `firstLeafPaneID` — the tree's *leftmost* leaf, which is the hidden
    /// A, even though the visible C sits right beside it. `visiblePanes`
    /// (`[C]`) is non-empty, so a check gated on emptiness alone would miss
    /// this. The fix moves focus off the hidden A onto the visible C
    /// instead — mirroring `hidePane`'s own behavior — rather than
    /// un-hiding A.
    @Test func closingAFocusedPaneMovesFocusOffAHiddenLeftmostLeafOntoAVisibleSibling() {
        let store = AppStateStore()
        let session = store.sessions[0]
        let paneA = session.tree.allPanes[0]
        let paneB = session.tree.splitFocusedPane(direction: .horizontal)
        let paneC = session.tree.splitPane(id: paneB.id, direction: .vertical)!
        store.windows[0].hidePane(id: paneA.id)
        session.tree.focusedPaneID = paneB.id
        #expect(paneA.isHidden)
        #expect(!paneC.isHidden)

        let outcome = store.closePane(id: paneB.id)

        #expect(outcome == .closed)
        #expect(paneA.isHidden, "A was never the pane that absorbed the closed pane's space and must stay hidden")
        #expect(session.tree.focusedPaneID == paneC.id,
                "focus must move off the hidden leftmost leaf onto the visible sibling, not linger on A")
        #expect(!session.tree.visiblePanes.isEmpty)
        #expect(!(session.tree.allPanes.first { $0.id == session.tree.focusedPaneID }?.isHidden ?? true),
                "focus must never sit on a hidden pane (#0256), even when another pane is still visible")
    }

    /// Proves the history-lookup step's `isHidden == false` filter is
    /// observable through the **production** `closePane` path, not only in
    /// isolation at the Model layer
    /// (`SplitTreeFocusHistoryTests
    /// .theHistoryLookupItselfSkipsAHiddenEntryRankedAheadOfAVisibleOne`).
    /// The key is that the correct answer here (the most recent *visible*
    /// history entry, `recentVisibleSurvivor`) is **not** the same value
    /// `WindowRuntime`'s hidden-pane backstop would produce on its own
    /// (`visiblePanes.first`, which is `main`) — so a regression that drops
    /// the filter is still caught even though the backstop papers over the
    /// worse case of a hidden pane actually being exposed. History reads
    /// [`focused`, `recentHiddenSurvivor`, `recentVisibleSurvivor`] going
    /// into the close; `recentHiddenSurvivor` ranks ahead of
    /// `recentVisibleSurvivor` but is hidden, so it must be skipped.
    @Test func closingFallsBackToTheMostRecentVisibleHistoryEntryNotTheFirstVisiblePane() {
        let store = AppStateStore()
        let session = store.sessions[0]
        let main = session.tree.allPanes[0]
        let focused = session.tree.splitFocusedPane(direction: .horizontal)
        let recentVisibleSurvivor = session.tree.splitPane(id: main.id, direction: .vertical)!
        let recentHiddenSurvivor = session.tree.splitPane(id: recentVisibleSurvivor.id, direction: .vertical)!
        session.tree.focusedPaneID = recentVisibleSurvivor.id
        session.tree.focusedPaneID = recentHiddenSurvivor.id
        session.tree.focusedPaneID = focused.id
        store.windows[0].hidePane(id: recentHiddenSurvivor.id)
        #expect(recentHiddenSurvivor.isHidden)

        #expect(store.closePane(id: focused.id) == .closed)

        #expect(session.tree.focusedPaneID == recentVisibleSurvivor.id,
                "recentHiddenSurvivor ranks ahead of recentVisibleSurvivor in history but is hidden, so the history lookup must skip it — landing on main (visiblePanes.first, the hidden-pane backstop's own answer) would mean the filter is gone")
    }

    @Test func closingAPaneLeavesAnAlreadyVisibleSiblingsHiddenStateAlone() {
        let store = AppStateStore()
        let session = store.sessions[0]
        let paneA = session.tree.allPanes[0]
        let paneB = session.tree.splitFocusedPane(direction: .horizontal)
        // A third pane, C, stays visible and focused after A closes, so
        // nothing needs to un-hide B — the invariant (≥1 visible pane, focus
        // not on a hidden pane) already holds without touching B.
        let paneC = session.tree.splitPane(id: paneB.id, direction: .vertical)!
        store.windows[0].hidePane(id: paneB.id)
        session.tree.focusedPaneID = paneC.id
        #expect(paneB.isHidden)

        let outcome = store.closePane(id: paneA.id)

        #expect(outcome == .closed)
        #expect(paneB.isHidden, "B was not the pane that absorbed A's space and must stay hidden")
        #expect(session.tree.visiblePanes.contains { $0.id == paneC.id })
        #expect(session.tree.focusedPaneID == paneC.id,
                "closing A, which was neither focused nor hidden, must not disturb focus already on a visible pane")
    }

    // MARK: - Background-session close must not steal focus or switch the
    // active session (#0257, same discipline as #0282's split tests)

    @Test func closingAPaneInABackgroundSessionDoesNotChangeSelectionOrTheForegroundSessionsFocus() {
        let store = AppStateStore()
        let selected = store.sessions[0]
        let background = store.addSession(title: "Background")!
        store.windows[0].selectedSessionID = selected.id
        let backgroundPaneA = background.tree.allPanes[0]
        let backgroundPaneB = background.tree.splitFocusedPane(direction: .horizontal)
        let selectedFocusedPaneBefore = selected.tree.focusedPaneID
        let selectedSessionIDBefore = store.windows[0].selectedSessionID

        let outcome = store.closePane(id: backgroundPaneA.id)

        #expect(outcome == .closed)
        #expect(store.windows[0].selectedSessionID == selectedSessionIDBefore,
                "closing a pane in a background session must not change the window's selected session")
        #expect(selected.tree.focusedPaneID == selectedFocusedPaneBefore,
                "closing a pane in a background session must not change the foreground session's focus")
        #expect(background.tree.allPanes.count == 1)
        #expect(background.tree.allPanes[0].id == backgroundPaneB.id)
    }

    @Test func closePaneResolvesAPaneInANonKeyWindow() {
        let store = AppStateStore()
        let w2 = store.windowRuntime(for: WindowID())
        let target = w2.sessions[0].tree.allPanes[0]
        w2.sessions[0].tree.splitFocusedPane(direction: .horizontal)

        let outcome = store.closePane(id: target.id)

        #expect(outcome == .closed)
        #expect(!w2.sessions[0].tree.allPanes.contains { $0.id == target.id })
    }

    // MARK: - Last pane of a non-last session: closes the session, not the app

    @Test func closingTheLastPaneOfANonLastSessionClosesThatSessionOnly() {
        let store = AppStateStore()
        let firstSession = store.sessions[0]
        let secondSession = store.addSession()!
        store.selectedSessionID = firstSession.id
        let onlyPaneID = secondSession.tree.allPanes[0].id

        let outcome = store.closePane(id: onlyPaneID)

        #expect(outcome == .closed)
        #expect(store.sessions.count == 1)
        #expect(store.sessions.first?.id == firstSession.id)
    }

    // MARK: - Last pane in the entire app: refused rather than walking into
    // #0217's silent-quit cascade with no human in the loop

    @Test func closingTheAppsVeryLastPaneIsRefused() {
        let store = AppStateStore()
        let onlyPaneID = store.sessions[0].tree.allPanes[0].id

        let outcome = store.closePane(id: onlyPaneID)

        #expect(outcome == .refusedLastPane)
        #expect(store.sessions.count == 1, "a refused close must leave the session untouched")
        #expect(store.sessions[0].tree.allPanes.count == 1)
    }

    @Test func closingTheLastPaneOfAWindowIsAllowedWhenAnotherWindowStillHasSessions() {
        let store = AppStateStore()
        let onlyPaneID = store.sessions[0].tree.allPanes[0].id
        // A second window keeps the app alive even after this window empties,
        // so the app-wide last-pane guard does not apply here.
        _ = store.windowRuntime(for: WindowID())

        nonisolated(unsafe) var windowEmptied = false
        store.windows[0].onAllSessionsClosed = { windowEmptied = true }

        let outcome = store.closePane(id: onlyPaneID)

        #expect(outcome == .closed)
        #expect(windowEmptied, "this window's own last-session cascade is unaffected by the app-wide guard")
    }

    /// Regression coverage for round 1's required fix: the refusal used to
    /// proxy "the app has one pane left" with `windows.count == 1`, which a
    /// `WindowRuntime` left in `store.windows` with an empty `sessions`
    /// array (possible when its last session closes before `RootWindowView`
    /// wires `closeWindowCallback` — see that property's doc comment) would
    /// have fooled: `windows.count` reads `2` even though only one pane
    /// exists anywhere. Counting panes directly is immune to this.
    @Test func totalPaneCountIgnoresAWindowThatLingersWithNoSessions() {
        let store = AppStateStore()
        let onlyPaneID = store.sessions[0].tree.allPanes[0].id
        let w2 = store.windowRuntime(for: WindowID())
        w2.removeSession(id: w2.sessions[0].id)
        #expect(w2.sessions.isEmpty)
        #expect(store.windows.count == 2,
                "the empty runtime lingers in `windows` — exactly the shape the old proxy misread")

        let outcome = store.closePane(id: onlyPaneID)

        #expect(outcome == .refusedLastPane)
    }
}
