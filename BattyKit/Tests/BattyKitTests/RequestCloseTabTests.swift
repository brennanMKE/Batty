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
