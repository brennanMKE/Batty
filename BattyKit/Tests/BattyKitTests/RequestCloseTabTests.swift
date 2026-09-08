// RequestCloseTabTests.swift

import Foundation
import Testing
@testable import BattyKit

@MainActor
struct RequestCloseTabTests {

    // TerminalViewState+Polyfill.swift hard-codes needsConfirmClose to an
    // unconditional `false` regardless of surface state — not the
    // surface?.needsConfirmClose ?? false this comment used to claim (that
    // described #0054's intended fork-side implementation, never the code
    // that shipped). Every test in this file that doesn't set
    // TabRuntime.needsConfirmCloseOverride exercises the idle path against
    // a real (surfaceless, in these unit tests) TerminalViewState; the busy
    // path is covered via that override (#0398) below, and remains
    // integration-only against a live ghostty_surface_t reporting a real
    // busy process.

    @Test func requestCloseTabOnIdleTabClosesImmediately() {
        let store = AppStateStore()
        let session = store.sessions[0]
        let pane = session.tree.allPanes[0]
        pane.addTab()
        let target = pane.tabs[0].id
        #expect(pane.tabs.count == 2)

        store.requestCloseTab(id: target)

        #expect(pane.tabs.count == 1)
        #expect(!pane.tabs.contains { $0.id == target })
        #expect(store.pendingCloseRequest == nil)
    }

    /// #0398: the previously-unreachable half of `requestCloseTab` —
    /// forcing `TabRuntime.needsConfirmCloseOverride` lets this drive the
    /// dialog branch without a live surface. Non-default fixture: the tab
    /// starts idle (the type's default) and is flipped busy explicitly, so
    /// this doesn't pass merely because "no pending request" was already
    /// the starting state.
    @Test func requestCloseTabOnABusyTabRaisesAConfirmationInsteadOfClosing() {
        let store = AppStateStore()
        let session = store.sessions[0]
        let pane = session.tree.allPanes[0]
        pane.addTab()
        let target = pane.tabs[0]
        target.needsConfirmCloseOverride = true
        #expect(pane.tabs.count == 2)
        #expect(store.pendingCloseRequest == nil, "precondition: nothing pending yet")

        store.requestCloseTab(id: target.id)

        #expect(pane.tabs.count == 2, "a busy tab must not close before the dialog is confirmed")
        #expect(pane.tabs.contains { $0.id == target.id })
        guard case .singleTab(let tabID) = store.pendingCloseRequest?.kind else {
            Issue.record("expected requestCloseTab to raise a .singleTab pending close request")
            return
        }
        #expect(tabID == target.id)
        // #0398 review round 1, N1: pins the dialog message too — a fresh
        // TabRuntime's terminal.title is "" (no live surface), which
        // Self.runningLabel(for:) maps to "A process".
        #expect(store.pendingCloseRequest?.message == "A process is still running. Closing this tab will end it.")
    }

    @Test func requestCloseFocusedTabRoutesThroughTheCascade() {
        let store = AppStateStore()
        let session = store.sessions[0]
        let pane = session.tree.allPanes[0]
        pane.addTab()
        let activeID = pane.activeTabID
        #expect(pane.tabs.count == 2)

        store.requestCloseFocusedTab()

        #expect(pane.tabs.count == 1)
        #expect(!pane.tabs.contains { $0.id == activeID })
    }

    /// #0315 review round 2, finding 2: `WindowRuntime.requestCloseFocusedTab()`
    /// / `.closeFocusedTab()` are the single choke point every dispatch
    /// path (menu bar, `BattyShortcuts`, Command Palette) routes "close the
    /// focused tab" through — a non-terminal pane's structural placeholder
    /// tab must never be mutated by the Tab-close path.
    ///
    /// #0334 changed what these methods do instead: since #0315 gated the
    /// Tab commands (including this one) to `.terminal` panes, closing the
    /// *tab* correctly never touched the placeholder — but that also left
    /// non-terminal panes with no ⌘W/menu route to being closed at all.
    /// Both methods now close the **Pane** itself when the focused pane
    /// isn't `.terminal`-kind, verified below.
    @Test func closeFocusedTabClosesTheFocusedNonTerminalPane() {
        let store = AppStateStore()
        let session = store.sessions[0]
        let terminalPane = session.focusedPaneAnyKind
        let nonTerminalPane = session.tree.splitPane(id: terminalPane.id, direction: .horizontal, kind: .systemMetrics)!
        #expect(session.tree.focusedPaneID == nonTerminalPane.id)
        let paneCountBefore = session.tree.allPanes.count

        store.windows[0].closeFocusedTab()

        #expect(session.tree.allPanes.count == paneCountBefore - 1,
                "closeFocusedTab() must close a non-terminal focused pane, not no-op")
        #expect(!session.tree.allPanes.contains { $0.id == nonTerminalPane.id })
    }

    @Test func requestCloseFocusedTabClosesTheFocusedNonTerminalPane() {
        let store = AppStateStore()
        let session = store.sessions[0]
        let terminalPane = session.focusedPaneAnyKind
        // `contentFactory: { _ in nil }` avoids constructing a real `GitStatusPaneContent` (and its real `FSEventStream`) as a side effect of this test's setup -- any non-terminal kind would do, and #0313's injectable-factory seam is the correct way to keep one inert, not swapping to a conformer-less kind (review round 3: that just moves the hazard onto whichever kind is picked next).
        let nonTerminalPane = session.tree.splitPane(id: terminalPane.id, direction: .horizontal, kind: .gitStatus, contentFactory: { _ in nil })!
        // Permanent regression check, not just a comment's promise: if a
        // future edit drops the `contentFactory` argument above, this
        // fails loudly instead of silently starting a real FSEventStream
        // (review round 3's own point: "the suite will still pass if you
        // miss one").
        #expect(nonTerminalPane.content == nil)
        #expect(session.tree.focusedPaneID == nonTerminalPane.id)
        let paneCountBefore = session.tree.allPanes.count

        store.windows[0].requestCloseFocusedTab()

        #expect(session.tree.allPanes.count == paneCountBefore - 1,
                "requestCloseFocusedTab() must close a non-terminal focused pane, not no-op")
        #expect(!session.tree.allPanes.contains { $0.id == nonTerminalPane.id })
    }

    /// The `.terminal`-kind sibling must be unaffected: closing a
    /// non-terminal pane closes only that pane, leaving the terminal
    /// pane's own tabs alone.
    @Test func closingANonTerminalFocusedPaneDoesNotTouchTheTerminalSiblingsTabs() {
        let store = AppStateStore()
        let session = store.sessions[0]
        let terminalPane = session.focusedPaneAnyKind
        let tabCountBefore = terminalPane.tabs.count
        // contentFactory: { _ in nil } -- this test is about the terminal
        // sibling's tabs being unaffected by closing a non-terminal pane,
        // not .processStatus's own behavior (review round 3,
        // post-#0313-rebase).
        let nonTerminalPane = session.tree.splitPane(id: terminalPane.id, direction: .horizontal, kind: .processStatus, contentFactory: { _ in nil })!
        // Permanent regression check — see CommandPaletteViewActionTests's
        // comment on the same pattern.
        #expect(nonTerminalPane.content == nil)
        #expect(session.tree.focusedPaneID == nonTerminalPane.id)

        store.windows[0].closeFocusedTab()

        #expect(terminalPane.tabs.count == tabCountBefore)
        #expect(session.tree.allPanes.contains { $0.id == terminalPane.id })
    }

    // MARK: - `WindowRuntime.closeFocusedItemTitle` (#0334)

    @Test func closeFocusedItemTitleIsCloseTabForATerminalFocusedPane() {
        let store = AppStateStore()
        #expect(store.sessions[0].focusedPaneAnyKind.kind == .terminal, "test setup: default pane is terminal-kind")

        #expect(store.windows[0].closeFocusedItemTitle == "Close Tab")
    }

    @Test func closeFocusedItemTitleIsClosePaneForANonTerminalFocusedPane() {
        let store = AppStateStore()
        let session = store.sessions[0]
        let terminalPane = session.focusedPaneAnyKind
        // contentFactory: { _ in nil } — this test only needs a
        // non-terminal *kind* to check the menu-item title, and never
        // closes the pane afterward; without the override,
        // `.lmStudioDashboard`'s real conformer would `setUp()` a real
        // subprocess/HTTP poll that outlives this test.
        let nonTerminalPane = session.tree.splitPane(id: terminalPane.id, direction: .horizontal, kind: .lmStudioDashboard, contentFactory: { _ in nil })!
        #expect(session.tree.focusedPaneID == nonTerminalPane.id)

        #expect(store.windows[0].closeFocusedItemTitle == "Close Pane")
    }

    @Test func requestCloseOtherTabsAllIdleClosesImmediately() {
        let pane = PaneRuntime()
        pane.addTab()
        pane.addTab()
        let store = AppStateStore(sessions: [
            SessionRuntime(tree: SplitTree(root: .leaf(pane)))
        ])
        let keeperID = pane.tabs[1].id

        store.requestCloseOtherTabs(paneID: pane.id, keepingTabID: keeperID)

        #expect(pane.tabs.count == 1)
        #expect(pane.activeTabID == keeperID)
        #expect(store.pendingCloseRequest == nil)
    }

    /// #0398: `requestCloseOtherTabs`'s dialog branch, previously
    /// unreachable in any environment.
    @Test func requestCloseOtherTabsWithABusyVictimRaisesAConfirmation() {
        let pane = PaneRuntime()
        pane.addTab()
        pane.addTab()
        let store = AppStateStore(sessions: [
            SessionRuntime(tree: SplitTree(root: .leaf(pane)))
        ])
        let keeperID = pane.tabs[2].id
        let busyVictim = pane.tabs[0]
        busyVictim.needsConfirmCloseOverride = true
        let tabCountBefore = pane.tabs.count

        store.requestCloseOtherTabs(paneID: pane.id, keepingTabID: keeperID)

        #expect(pane.tabs.count == tabCountBefore, "busy victims must not close before confirmation")
        guard case .otherTabs(let paneID, let keepingTabID) = store.pendingCloseRequest?.kind else {
            Issue.record("expected requestCloseOtherTabs to raise an .otherTabs pending close request")
            return
        }
        #expect(paneID == pane.id)
        #expect(keepingTabID == keeperID)
        // #0398 review round 1, N1: only 1 of the 2 victims is busy, so
        // this pins the "N of M" message branch specifically, distinct
        // from the "all of these tabs" branch that fires when every
        // victim is busy.
        #expect(store.pendingCloseRequest?.message == "1 of the 2 tabs about to close are running processes.")
    }

    @Test func confirmPendingCloseSingleTabClosesAndClears() {
        let store = AppStateStore()
        let session = store.sessions[0]
        let pane = session.tree.allPanes[0]
        pane.addTab()
        let target = pane.tabs[0].id
        store.pendingCloseRequest = PendingCloseRequest(
            kind: .singleTab(tabID: target),
            message: "test"
        )

        store.confirmPendingClose()

        #expect(pane.tabs.count == 1)
        #expect(!pane.tabs.contains { $0.id == target })
        #expect(store.pendingCloseRequest == nil)
    }

    @Test func cancelPendingCloseLeavesEverythingAlone() {
        let store = AppStateStore()
        let pane = store.sessions[0].tree.allPanes[0]
        pane.addTab()
        let target = pane.tabs[0].id
        let originalCount = pane.tabs.count
        store.pendingCloseRequest = PendingCloseRequest(
            kind: .singleTab(tabID: target),
            message: "test"
        )

        store.cancelPendingClose()

        #expect(pane.tabs.count == originalCount)
        #expect(store.pendingCloseRequest == nil)
    }
}
