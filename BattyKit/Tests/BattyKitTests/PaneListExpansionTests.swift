// PaneListExpansionTests.swift

import Foundation
import Testing
@testable import BattyKit

/// #0258: the sidebar pane list is collapsible per session (chevron),
/// collapsed by default, and auto-expands when a pane is hidden so the
/// restore control stays reachable.
@MainActor
struct PaneListExpansionTests {

    @Test func paneListDefaultsCollapsed() {
        let session = SessionRuntime()
        #expect(session.isPaneListExpanded == false)
    }

    @Test func hidePaneAutoExpandsPaneList() {
        let store = AppStateStore()
        let session = store.sessions[0]
        let newPane = session.tree.splitFocusedPane(direction: .horizontal)
        #expect(session.isPaneListExpanded == false)

        store.windows[0].hidePane(id: newPane.id)

        #expect(newPane.isHidden)
        #expect(session.isPaneListExpanded == true)
    }

    @Test func refusedHideDoesNotExpandPaneList() {
        let store = AppStateStore()
        let session = store.sessions[0]
        let onlyPane = session.tree.focusedPane

        store.windows[0].hidePane(id: onlyPane.id)

        #expect(onlyPane.isHidden == false)
        #expect(session.isPaneListExpanded == false)
    }

    @Test func showPaneLeavesExpansionAlone() {
        let store = AppStateStore()
        let session = store.sessions[0]
        let newPane = session.tree.splitFocusedPane(direction: .horizontal)
        store.windows[0].hidePane(id: newPane.id)
        session.isPaneListExpanded = false

        store.windows[0].showPane(id: newPane.id)

        #expect(newPane.isHidden == false)
        #expect(session.isPaneListExpanded == false)
    }
}
