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
        let secondSession = store.addSession()
        store.selectedSessionID = firstSession.id

        let onlyTabID = secondSession.tree.allPanes[0].tabs[0].id
        store.closeTab(id: onlyTabID)

        #expect(store.sessions.count == 1)
        #expect(store.sessions.first?.id == firstSession.id)
    }

    @Test func closingTheLastTabOfTheLastSessionRestoresADefaultSession() {
        let store = AppStateStore()
        let session = store.sessions[0]
        let onlyTabID = session.tree.allPanes[0].tabs[0].id

        store.closeTab(id: onlyTabID)

        #expect(store.sessions.count == 1)
        #expect(store.sessions[0].id != session.id)
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
