// RequestCloseTabTests.swift

import Foundation
import Testing
@testable import BattyKit

@MainActor
struct RequestCloseTabTests {

    // Without a real attached surface, TerminalViewState.needsConfirmClose
    // returns false (surface?.needsConfirmClose ?? false). Every test here
    // exercises the idle path; the busy path is integration-only because
    // it requires a live ghostty_surface_t. The fork test suite covers the
    // ghostty_surface_needs_confirm_quit call itself.

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
        let terminalPane = session.focusedPane
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
        let terminalPane = session.focusedPane
        let nonTerminalPane = session.tree.splitPane(id: terminalPane.id, direction: .horizontal, kind: .gitStatus)!
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
        let terminalPane = session.focusedPane
        let tabCountBefore = terminalPane.tabs.count
        let nonTerminalPane = session.tree.splitPane(id: terminalPane.id, direction: .horizontal, kind: .processStatus)!
        #expect(session.tree.focusedPaneID == nonTerminalPane.id)

        store.windows[0].closeFocusedTab()

        #expect(terminalPane.tabs.count == tabCountBefore)
        #expect(session.tree.allPanes.contains { $0.id == terminalPane.id })
    }

    // MARK: - `WindowRuntime.closeFocusedItemTitle` (#0334)

    @Test func closeFocusedItemTitleIsCloseTabForATerminalFocusedPane() {
        let store = AppStateStore()
        #expect(store.sessions[0].focusedPane.kind == .terminal, "test setup: default pane is terminal-kind")

        #expect(store.windows[0].closeFocusedItemTitle == "Close Tab")
    }

    @Test func closeFocusedItemTitleIsClosePaneForANonTerminalFocusedPane() {
        let store = AppStateStore()
        let session = store.sessions[0]
        let terminalPane = session.focusedPane
        let nonTerminalPane = session.tree.splitPane(id: terminalPane.id, direction: .horizontal, kind: .lmStudioDashboard)!
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
