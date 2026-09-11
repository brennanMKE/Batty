// JumpToTabHiddenPaneTests.swift

import Foundation
import Testing
@testable import BattyKit

@MainActor
struct JumpToTabHiddenPaneTests {

    // #0405: `jumpToTab` must un-hide its target pane before moving focus
    // to it, same as `jumpToBellEntry`, `focusPaneForXPC`, and
    // `focusTabForXPC` already do (#0256's invariant). The fixture uses
    // three distinct panes — a hidden target, a previously focused pane,
    // and the session's first pane — so the assertions can't pass
    // vacuously by any two of those roles landing on the same pane.
    @Test func jumpToTabUnhidesHiddenTargetPane() {
        let bellFeed = BellFeedStore()
        let nameCache = SessionNameCache()
        let window = WindowRuntime(bellFeed: bellFeed, nameCache: nameCache)
        let session = window.sessions.first!

        let firstPane = session.focusedPaneAnyKind
        let previouslyFocusedPane = session.tree.splitFocusedPane(direction: .horizontal)
        let hiddenTargetPane = session.tree.splitFocusedPane(direction: .horizontal)

        // Re-focus the middle pane so it — not the newly split target — is
        // the "previously focused" pane at the moment of the jump.
        session.tree.focusedPaneID = previouslyFocusedPane.id

        window.hidePane(id: hiddenTargetPane.id)
        #expect(hiddenTargetPane.isHidden == true)
        #expect(session.tree.focusedPaneID == previouslyFocusedPane.id)

        // Sanity: three distinct panes are in play.
        #expect(firstPane.id != previouslyFocusedPane.id)
        #expect(previouslyFocusedPane.id != hiddenTargetPane.id)
        #expect(firstPane.id != hiddenTargetPane.id)

        let targetTab = hiddenTargetPane.activeTab!

        window.jumpToTab(sessionID: session.id, tabID: targetTab.id)

        #expect(hiddenTargetPane.isHidden == false)
        #expect(session.tree.focusedPaneID == hiddenTargetPane.id)
        #expect(hiddenTargetPane.activeTabID == targetTab.id)
    }
}
