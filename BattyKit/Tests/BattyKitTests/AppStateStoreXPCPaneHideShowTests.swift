// AppStateStoreXPCPaneHideShowTests.swift

import Foundation
import Testing
@testable import BattyKit

/// Covers `AppStateStore.hidePaneForXPC(id:)` / `.showPaneForXPC(id:)` —
/// #0382's XPC `pane hide`/`pane show` verbs. Both reuse the pre-existing
/// `WindowRuntime.hidePane(id:)`/`.showPane(id:)` (the sidebar eye toggle's
/// own entry points, already covered mechanically by `PaneHideTests.swift`)
/// for the actual mutation — this file covers only the outcome
/// classification the XPC wrapper adds on top: unknown-id, idempotent
/// already-hidden/already-visible, and the last-visible-pane refusal made
/// into a visible failure instead of `hidePane`'s silent no-op.
@MainActor
struct AppStateStoreXPCPaneHideShowTests {

    // MARK: - pane hide

    @Test func hidePaneForXPCHidesAVisiblePane() {
        let store = AppStateStore()
        let session = store.sessions[0]
        let paneA = session.tree.allPanes[0]
        let paneB = session.tree.splitFocusedPane(direction: .horizontal)

        let outcome = store.hidePaneForXPC(id: paneB.id)

        #expect(outcome == .hidden)
        #expect(paneB.isHidden)
        #expect(!paneA.isHidden)
    }

    @Test func hidePaneForXPCOnAnAlreadyHiddenPaneSucceedsQuietly() {
        let store = AppStateStore()
        let session = store.sessions[0]
        let paneA = session.tree.allPanes[0]
        let paneB = session.tree.splitFocusedPane(direction: .horizontal)
        store.windows[0].hidePane(id: paneB.id)
        #expect(paneB.isHidden)

        let outcome = store.hidePaneForXPC(id: paneB.id)

        #expect(outcome == .alreadyHidden, "idempotent: hiding an already-hidden pane must not error")
        #expect(paneB.isHidden)
        #expect(!paneA.isHidden)
    }

    @Test func hidePaneForXPCReturnsUnknownPaneForAStaleID() {
        let store = AppStateStore()
        #expect(store.hidePaneForXPC(id: UUID()) == .unknownPane)
    }

    @Test func hidePaneForXPCRefusesToHideASessionsLastVisiblePane() {
        let store = AppStateStore()
        let session = store.sessions[0]
        let onlyPane = session.tree.allPanes[0]

        let outcome = store.hidePaneForXPC(id: onlyPane.id)

        #expect(outcome == .refusedLastVisiblePane)
        #expect(!onlyPane.isHidden, "a refused hide must leave the pane visible")
    }

    @Test func hidePaneForXPCRefusesWhenEveryOtherPaneInTheSessionIsAlreadyHidden() {
        let store = AppStateStore()
        let session = store.sessions[0]
        let paneA = session.tree.allPanes[0]
        let paneB = session.tree.splitFocusedPane(direction: .horizontal)
        store.windows[0].hidePane(id: paneA.id)
        #expect(paneA.isHidden)
        #expect(session.tree.visiblePanes.map(\.id) == [paneB.id])

        let outcome = store.hidePaneForXPC(id: paneB.id)

        #expect(outcome == .refusedLastVisiblePane)
        #expect(!paneB.isHidden, "paneB must stay visible — it is the session's only visible pane")
    }

    @Test func hidePaneForXPCDoesNotChangeSelectionForABackgroundSession() {
        let store = AppStateStore()
        let selected = store.sessions[0]
        let background = store.addSession(title: "Background")!
        store.windows[0].selectedSessionID = selected.id
        let backgroundPaneA = background.tree.allPanes[0]
        _ = background.tree.splitFocusedPane(direction: .horizontal)

        let outcome = store.hidePaneForXPC(id: backgroundPaneA.id)

        #expect(outcome == .hidden)
        #expect(backgroundPaneA.isHidden)
        #expect(store.windows[0].selectedSessionID == selected.id,
                "hiding a pane in a background session must not change the window's selection")
    }

    // MARK: - pane show

    @Test func showPaneForXPCShowsAHiddenPane() {
        let store = AppStateStore()
        let session = store.sessions[0]
        let paneA = session.tree.allPanes[0]
        let paneB = session.tree.splitFocusedPane(direction: .horizontal)
        store.windows[0].hidePane(id: paneB.id)
        #expect(paneB.isHidden)

        let outcome = store.showPaneForXPC(id: paneB.id)

        #expect(outcome == .shown)
        #expect(!paneB.isHidden)
        #expect(!paneA.isHidden)
    }

    @Test func showPaneForXPCOnAnAlreadyVisiblePaneSucceedsQuietly() {
        let store = AppStateStore()
        let session = store.sessions[0]
        let onlyPane = session.tree.allPanes[0]
        #expect(!onlyPane.isHidden)

        let outcome = store.showPaneForXPC(id: onlyPane.id)

        #expect(outcome == .alreadyVisible, "idempotent: showing an already-visible pane must not error")
        #expect(!onlyPane.isHidden)
    }

    @Test func showPaneForXPCReturnsUnknownPaneForAStaleID() {
        let store = AppStateStore()
        #expect(store.showPaneForXPC(id: UUID()) == .unknownPane)
    }

    @Test func showPaneForXPCDoesNotChangeSelectionForABackgroundSession() {
        let store = AppStateStore()
        let selected = store.sessions[0]
        let background = store.addSession(title: "Background")!
        let backgroundPaneA = background.tree.allPanes[0]
        _ = background.tree.splitFocusedPane(direction: .horizontal)
        store.windows[0].hidePane(id: backgroundPaneA.id)
        #expect(backgroundPaneA.isHidden)
        store.windows[0].selectedSessionID = selected.id

        let outcome = store.showPaneForXPC(id: backgroundPaneA.id)

        #expect(outcome == .shown)
        #expect(!backgroundPaneA.isHidden)
        #expect(store.windows[0].selectedSessionID == selected.id,
                "showing a pane in a background session must not change the window's selection")
    }
}
