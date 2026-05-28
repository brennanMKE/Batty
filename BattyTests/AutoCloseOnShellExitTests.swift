// AutoCloseOnShellExitTests.swift

import Foundation
import Testing
@testable import BattyKit

@MainActor
struct AutoCloseOnShellExitTests {

    @Test func onCloseClosureRoutesThroughCloseTab() {
        let store = AppStateStore()
        let session = store.sessions[0]
        let pane = session.tree.allPanes[0]
        pane.addTab()
        #expect(pane.tabs.count == 2)
        let tabA = pane.tabs[0]
        let tabAID = tabA.id

        tabA.terminal.onClose = { [weak store] _ in
            store?.closeTab(id: tabAID)
        }
        tabA.terminal.onClose?(false)

        #expect(pane.tabs.count == 1)
        #expect(!pane.tabs.contains { $0.id == tabAID })
    }

    @Test func onCloseOnLastTabOfLastSessionResetsToFreshSession() {
        let store = AppStateStore()
        let session = store.sessions[0]
        let tab = session.tree.allPanes[0].tabs[0]
        let originalSessionID = session.id
        let originalTabID = tab.id

        tab.terminal.onClose = { [weak store] _ in
            store?.closeTab(id: originalTabID)
        }
        tab.terminal.onClose?(false)

        #expect(store.sessions.count == 1)
        #expect(!store.sessions.contains { $0.id == originalSessionID })
        #expect(store.selectedSessionID == store.sessions[0].id)
    }
}
