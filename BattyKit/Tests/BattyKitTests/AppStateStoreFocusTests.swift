// AppStateStoreFocusTests.swift

import Foundation
import Testing
@testable import BattyKit

@MainActor
struct AppStateStoreFocusTests {

    @Test func focusPaneMovesFocusedPaneIDWithinOwningSession() {
        let store = AppStateStore()
        let session = store.sessions[0]
        session.tree.splitFocusedPane(direction: .horizontal)
        let panes = session.tree.allPanes
        #expect(panes.count == 2)
        let targetPane = panes.first { $0.id != session.tree.focusedPaneID }!

        store.focusPane(id: targetPane.id)

        #expect(session.tree.focusedPaneID == targetPane.id)
    }

    @Test func focusPaneFindsCorrectSessionAmongMany() {
        let store = AppStateStore()
        let other = store.addSession()
        other.tree.splitFocusedPane(direction: .horizontal)
        let originalFocus = other.tree.focusedPaneID
        let targetPane = other.tree.allPanes.first { $0.id != originalFocus }!

        store.focusPane(id: targetPane.id)

        #expect(other.tree.focusedPaneID == targetPane.id)
    }

    @Test func focusPaneDoesNotChangeSelectedSession() {
        let store = AppStateStore()
        let firstSession = store.sessions[0]
        let secondSession = store.addSession()
        store.selectedSessionID = firstSession.id
        let targetPane = secondSession.tree.allPanes[0]

        store.focusPane(id: targetPane.id)

        #expect(store.selectedSessionID == firstSession.id)
        #expect(secondSession.tree.focusedPaneID == targetPane.id)
    }

    @Test func focusPaneIsNoOpForUnknownID() {
        let store = AppStateStore()
        let session = store.sessions[0]
        let before = session.tree.focusedPaneID

        store.focusPane(id: UUID())

        #expect(session.tree.focusedPaneID == before)
    }
}
