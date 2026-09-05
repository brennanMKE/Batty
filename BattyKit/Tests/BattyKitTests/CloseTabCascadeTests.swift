// CloseTabCascadeTests.swift

import Foundation
import Testing
@testable import BattyKit

@MainActor
struct CloseTabCascadeTests {

    @Test func closingNonLastTabJustRemovesIt() {
        let store = AppStateStore()
        let session = store.sessions[0]
        let pane = session.tree.allPanes[0]
        pane.addTab()
        let firstID = pane.tabs[0].id

        store.closeTab(id: firstID)

        #expect(pane.tabs.count == 1)
        #expect(store.sessions.count == 1)
    }

    @Test func closingLastTabInPaneWithSiblingsRemovesThePane() {
        let store = AppStateStore()
        let session = store.sessions[0]
        let originalPane = session.tree.allPanes[0]
        session.tree.splitFocusedPane(direction: .horizontal)
        #expect(session.tree.allPanes.count == 2)
        let onlyTabID = originalPane.tabs[0].id

        store.closeTab(id: onlyTabID)

        #expect(session.tree.allPanes.count == 1)
        #expect(store.sessions.count == 1)
    }

    @Test func closingLastTabInOnlyPaneClosesTheSession() {
        let store = AppStateStore()
        let firstSession = store.sessions[0]
        let secondSession = store.addSession()!
        store.selectedSessionID = firstSession.id

        let onlyTabID = secondSession.tree.allPanes[0].tabs[0].id
        store.closeTab(id: onlyTabID)

        #expect(store.sessions.count == 1)
        #expect(store.sessions.first?.id == firstSession.id)
    }

    @Test func closingLastSessionTabEmptiesTheStore() {
        let store = AppStateStore()
        let onlyTabID = store.sessions[0].tree.allPanes[0].tabs[0].id

        nonisolated(unsafe) var called = false
        store.onAllSessionsClosed = { called = true }

        store.closeTab(id: onlyTabID)

        #expect(store.sessions.isEmpty)
        #expect(called)
    }

    @Test func closeOtherTabsKeepsTheTargetActive() {
        let pane = PaneRuntime()
        pane.addTab()
        pane.addTab()
        #expect(pane.tabs.count == 3)
        let keeperID = pane.tabs[1].id

        pane.closeOtherTabs(keeping: keeperID)

        #expect(pane.tabs.count == 1)
        #expect(pane.activeTabID == keeperID)
    }

    @Test func closeOtherTabsIsNoOpForUnknownID() {
        let pane = PaneRuntime()
        let originalCount = pane.tabs.count
        pane.closeOtherTabs(keeping: UUID())
        #expect(pane.tabs.count == originalCount)
    }

    /// #0337: the `closeTab` last-Tab cascade must produce the same
    /// recency-based successor as `AppStateStore.closePane(id:)`
    /// (`AppStateStoreClosePaneTests
    /// .closingThreeSequentialPanesWalksFocusBackByRecencyNotPosition`) —
    /// both routes converge on `SplitTree.removePane`, but before #0337
    /// this cascade had no post-remove focus fixup of any kind (see the
    /// issue's "Do the close paths diverge?" table), so it's the one that
    /// most directly proves the fix isn't `closePane`-only.
    @Test func closingLastTabInThreeSequentialPanesWalksFocusBackByRecency() {
        let store = AppStateStore()
        let session = store.sessions[0]
        let main = session.tree.allPanes[0]
        let paneA = session.tree.splitFocusedPane(direction: .horizontal)
        let paneB = session.tree.splitFocusedPane(direction: .horizontal)
        let paneC = session.tree.splitFocusedPane(direction: .horizontal)
        session.tree.focusedPaneID = paneA.id
        session.tree.focusedPaneID = paneB.id
        session.tree.focusedPaneID = paneC.id

        store.closeTab(id: paneC.tabs[0].id)
        #expect(session.tree.focusedPaneID == paneB.id,
                "the closeTab cascade must match closePane's recency-based successor, not fall back to firstLeafPaneID")

        store.closeTab(id: paneB.tabs[0].id)
        #expect(session.tree.focusedPaneID == paneA.id)

        store.closeTab(id: paneA.tabs[0].id)
        #expect(session.tree.focusedPaneID == main.id)
    }

    /// #0337's other closeTab-specific gap: the cascade had no hidden-pane
    /// fixup at all before this issue, unlike `closePane`
    /// (`AppStateStoreClosePaneTests
    /// .closingTheVisibleFocusedPaneUnhidesTheHiddenSiblingThatAbsorbsItsSpace`).
    /// Without `WindowRuntime.closeTab` calling
    /// `resolveHiddenFocusFallback(in:)`, this would leave paneB hidden and
    /// focus dangling on it.
    @Test func closingLastTabWithAHiddenSiblingUnhidesItJustLikeClosePaneDoes() {
        let store = AppStateStore()
        let session = store.sessions[0]
        let paneA = session.tree.allPanes[0]
        let paneB = session.tree.splitFocusedPane(direction: .horizontal)
        session.tree.focusedPaneID = paneA.id
        store.windows[0].hidePane(id: paneB.id)
        #expect(paneB.isHidden)

        store.closeTab(id: paneA.tabs[0].id)

        #expect(session.tree.allPanes.count == 1)
        #expect(!paneB.isHidden,
                "paneB inherited paneA's space; the closeTab cascade must un-hide it, same as closePane")
        #expect(session.tree.focusedPaneID == paneB.id)
    }

    @Test func closeFocusedTabRoutesThroughTheCascade() {
        let store = AppStateStore()
        let session = store.sessions[0]
        let pane = session.tree.allPanes[0]
        pane.addTab()
        let activeID = pane.activeTabID
        #expect(pane.tabs.count == 2)

        store.closeFocusedTab()

        #expect(pane.tabs.count == 1)
        #expect(pane.tabs.first?.id != activeID)
    }
}
