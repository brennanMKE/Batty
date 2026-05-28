// FocusThenSplitTests.swift

import Foundation
import Testing
@testable import BattyKit

@MainActor
struct FocusThenSplitTests {

    @Test func focusPaneThenSplitTargetsTheFocusedPane() {
        let store = AppStateStore()
        let session = store.sessions[0]
        let paneA = session.tree.allPanes[0]
        session.tree.splitFocusedPane(direction: .horizontal)
        let paneB = session.tree.allPanes.first { $0.id != paneA.id }!
        #expect(session.tree.focusedPaneID == paneB.id)

        store.focusPane(id: paneA.id)
        #expect(session.tree.focusedPaneID == paneA.id)

        session.tree.splitFocusedPane(direction: .horizontal)

        let paneCount = session.tree.allPanes.count
        #expect(paneCount == 3)
        let panesWithA = session.tree.allPanes.contains { $0.id == paneA.id }
        let panesWithB = session.tree.allPanes.contains { $0.id == paneB.id }
        #expect(panesWithA)
        #expect(panesWithB)
    }

    @Test func directFocusedPaneIDWriteThenSplitTargetsThatPane() {
        let store = AppStateStore()
        let session = store.sessions[0]
        let paneA = session.tree.allPanes[0]
        session.tree.splitFocusedPane(direction: .vertical)
        let paneB = session.tree.allPanes.first { $0.id != paneA.id }!
        #expect(session.tree.focusedPaneID == paneB.id)

        session.tree.focusedPaneID = paneA.id

        session.tree.splitFocusedPane(direction: .vertical)
        #expect(session.tree.allPanes.count == 3)
        #expect(session.tree.allPanes.contains { $0.id == paneA.id })
        #expect(session.tree.allPanes.contains { $0.id == paneB.id })
    }
}
