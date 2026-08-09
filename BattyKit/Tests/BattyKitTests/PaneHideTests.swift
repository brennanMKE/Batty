// PaneHideTests.swift

import Foundation
import Testing
@testable import BattyKit

// MARK: - Helpers shared across tests

// Walk the tree to compute the effective ratio-based fraction for a leaf pane.
// Returns nil if paneID is not in the subtree.
private func fraction(of paneID: UUID, in node: SplitTreeNode, available: Double = 1.0) -> Double? {
    switch node {
    case .leaf(let pane):
        return pane.id == paneID ? available : nil
    case .split(_, _, let ratio, let left, let right):
        return fraction(of: paneID, in: left, available: available * ratio)
            ?? fraction(of: paneID, in: right, available: available * (1.0 - ratio))
    }
}

private func isApprox(_ a: Double, _ b: Double, tolerance: Double = 1e-9) -> Bool {
    abs(a - b) < tolerance
}

// MARK: - PaneHideTests

@MainActor
struct PaneHideTests {

    // MARK: 1. Pane value-type Codable round-trip

    @Test func paneValueTypeCodableRoundTrip() throws {
        let id = UUID()
        let pane = Pane(id: id, isHidden: true)
        let data = try JSONEncoder().encode(pane)
        let decoded = try JSONDecoder().decode(Pane.self, from: data)
        #expect(decoded.id == id)
        #expect(decoded.isHidden == true)
    }

    @Test func paneValueTypeDefaultIsNotHidden() throws {
        let pane = Pane()
        #expect(pane.isHidden == false)
        let data = try JSONEncoder().encode(pane)
        let decoded = try JSONDecoder().decode(Pane.self, from: data)
        #expect(decoded.isHidden == false)
    }

    @Test func paneRuntimeSnapshotRoundTrip() throws {
        let runtime = PaneRuntime(isHidden: true)
        let snap = runtime.snapshot()
        #expect(snap.id == runtime.id)
        #expect(snap.isHidden == true)
        let data = try JSONEncoder().encode(snap)
        let decoded = try JSONDecoder().decode(Pane.self, from: data)
        #expect(decoded.id == runtime.id)
        #expect(decoded.isHidden == true)
    }

    // MARK: 2. Equalization counts visible panes only

    /// Hide one of two panes, split the visible one → the two visible panes
    /// each get 1/2 ratio, not 1/3. Without the fix they each got 1/3 because
    /// the hidden pane was still counted.
    @Test func equalizationSkipsHiddenPanesTwoVisible() {
        let tree = SplitTree()
        let paneA = tree.focusedPane

        // Two horizontal panes: A | B
        let paneB = tree.splitFocusedPane(direction: .horizontal)

        // Hide B
        paneB.isHidden = true

        // Split A → C (horizontal). Chain: A | C | B(hidden).
        tree.focusedPaneID = paneA.id
        let paneC = tree.splitFocusedPane(direction: .horizontal)

        // With visible-only equalization: A and C each 1/2 (2 visible units).
        // Without fix: 3 total units → each 1/3.
        #expect(isApprox(fraction(of: paneA.id, in: tree.root)!, 0.5))
        #expect(isApprox(fraction(of: paneC.id, in: tree.root)!, 0.5))
        // Hidden B gets ~0 ratio.
        #expect((fraction(of: paneB.id, in: tree.root) ?? 0.0) < 0.01)
    }

    /// Three horizontal panes, hide one, split one of the remaining two.
    /// The three visible panes should each get 1/3, not 1/4.
    @Test func equalizationSkipsHiddenPaneThreeVisible() {
        let tree = SplitTree()
        let paneA = tree.focusedPane

        // Three horizontal panes: A | B | C
        let paneB = tree.splitFocusedPane(direction: .horizontal)
        tree.focusedPaneID = paneB.id
        let paneC = tree.splitFocusedPane(direction: .horizontal)

        // Hide C
        paneC.isHidden = true

        // Split A → D. Visible: A, B, D. Hidden: C.
        tree.focusedPaneID = paneA.id
        let paneD = tree.splitFocusedPane(direction: .horizontal)

        let fracA = fraction(of: paneA.id, in: tree.root)!
        let fracB = fraction(of: paneB.id, in: tree.root)!
        let fracD = fraction(of: paneD.id, in: tree.root)!

        // Each of the 3 visible panes should get 1/3.
        #expect(isApprox(fracA, 1.0 / 3.0, tolerance: 1e-9))
        #expect(isApprox(fracB, 1.0 / 3.0, tolerance: 1e-9))
        #expect(isApprox(fracD, 1.0 / 3.0, tolerance: 1e-9))
        // Hidden C gets ~0 ratio.
        #expect((fraction(of: paneC.id, in: tree.root) ?? 0.0) < 0.01)
    }

    // MARK: 3. Focus moves off a hidden pane

    @Test func focusMovesOffHiddenPaneViaWindowRuntime() {
        let store = AppStateStore()
        let session = store.sessions.first!
        let paneA = session.focusedPane

        // Add a second pane
        let paneB = session.tree.splitFocusedPane(direction: .horizontal)
        // Focus A
        session.tree.focusedPaneID = paneA.id
        #expect(session.tree.focusedPaneID == paneA.id)

        // Hide A (the focused pane) via store
        store.hidePane(id: paneA.id)

        // Focus should have moved to B
        #expect(session.tree.focusedPaneID == paneB.id)
        #expect(paneA.isHidden == true)
    }

    @Test func focusMovesOffHiddenPaneViaWindowRuntimeDirect() {
        let bellFeed = BellFeedStore()
        let nameCache = SessionNameCache()
        let window = WindowRuntime(bellFeed: bellFeed, nameCache: nameCache)
        let session = window.sessions.first!
        let paneA = session.focusedPane

        let paneB = session.tree.splitFocusedPane(direction: .horizontal)
        session.tree.focusedPaneID = paneB.id
        #expect(session.tree.focusedPaneID == paneB.id)

        // Hide B (the focused pane)
        window.hidePane(id: paneB.id)

        // Focus should have moved to A
        #expect(session.tree.focusedPaneID == paneA.id)
        #expect(paneB.isHidden == true)
    }

    @Test func hidingUnfocusedPaneLeavesFocusUnchanged() {
        let store = AppStateStore()
        let session = store.sessions.first!
        let paneA = session.focusedPane

        let paneB = session.tree.splitFocusedPane(direction: .horizontal)
        // Focus A (not B)
        session.tree.focusedPaneID = paneA.id

        // Hide B (not the focused pane)
        store.hidePane(id: paneB.id)

        // Focus should still be on A
        #expect(session.tree.focusedPaneID == paneA.id)
        #expect(paneB.isHidden == true)
    }

    // MARK: 4. jumpToBellEntry un-hides a hidden pane

    @Test func jumpToBellEntryUnhidesHiddenPane() {
        let bellFeed = BellFeedStore()
        let nameCache = SessionNameCache()
        let window = WindowRuntime(bellFeed: bellFeed, nameCache: nameCache)
        let session = window.sessions.first!
        let paneA = session.focusedPane

        let paneB = session.tree.splitFocusedPane(direction: .horizontal)

        // Hide paneB
        window.hidePane(id: paneB.id)
        #expect(paneB.isHidden == true)
        #expect(session.tree.focusedPaneID == paneA.id)

        // Create a bell entry pointing at paneB
        let tabB = paneB.activeTab!
        let entry = BellFeedEntry(
            timestamp: Date(),
            windowID: window.id.value,
            sessionID: session.id,
            paneID: paneB.id,
            tabID: tabB.id,
            surfaceID: UUID(),
            message: nil,
            seen: false
        )

        // Jump to the bell entry
        window.jumpToBellEntry(entry)

        // paneB should now be visible and focused
        #expect(paneB.isHidden == false)
        #expect(session.tree.focusedPaneID == paneB.id)
        #expect(paneB.activeTabID == tabB.id)
    }

    // MARK: 5. Cannot hide the last visible pane

    @Test func cannotHideLastVisiblePane() {
        let store = AppStateStore()
        let session = store.sessions.first!
        let paneA = session.focusedPane

        // Only one pane — hiding must be a no-op
        store.hidePane(id: paneA.id)
        #expect(paneA.isHidden == false)
    }

    @Test func cannotHideLastVisiblePaneWhenOthersAreHidden() {
        let store = AppStateStore()
        let session = store.sessions.first!
        let paneA = session.focusedPane

        // Add paneB, hide paneA (now B is the only visible pane)
        let paneB = session.tree.splitFocusedPane(direction: .horizontal)
        _ = paneB  // used below
        store.hidePane(id: paneA.id)
        #expect(paneA.isHidden == true)

        // Now paneB is the last visible pane — hiding it must be refused
        store.hidePane(id: paneB.id)
        #expect(paneB.isHidden == false)
    }

    @Test func windowRuntimeRefusesHidingLastVisiblePane() {
        let bellFeed = BellFeedStore()
        let nameCache = SessionNameCache()
        let window = WindowRuntime(bellFeed: bellFeed, nameCache: nameCache)
        let session = window.sessions.first!
        let paneA = session.focusedPane

        // One pane — refuse
        window.hidePane(id: paneA.id)
        #expect(paneA.isHidden == false)

        // Add a sibling and hide paneA
        let paneB = session.tree.splitFocusedPane(direction: .horizontal)
        window.hidePane(id: paneA.id)
        #expect(paneA.isHidden == true)

        // paneB is last visible — refuse
        window.hidePane(id: paneB.id)
        #expect(paneB.isHidden == false)
    }

    // MARK: 6. isEntirelyHidden helper

    @Test func isEntirelyHiddenForSingleHiddenLeaf() {
        let pane = PaneRuntime(isHidden: true)
        let node = SplitTreeNode.leaf(pane)
        #expect(node.isEntirelyHidden == true)
    }

    @Test func isEntirelyHiddenForSingleVisibleLeaf() {
        let pane = PaneRuntime()
        let node = SplitTreeNode.leaf(pane)
        #expect(node.isEntirelyHidden == false)
    }

    @Test func isEntirelyHiddenForSplitWithMixedVisibility() {
        let hiddenPane = PaneRuntime(isHidden: true)
        let visiblePane = PaneRuntime()
        let node = SplitTreeNode.split(
            id: UUID(),
            direction: .horizontal,
            ratio: 0.5,
            left: .leaf(hiddenPane),
            right: .leaf(visiblePane)
        )
        #expect(node.isEntirelyHidden == false)
    }

    @Test func isEntirelyHiddenForSplitWithAllHidden() {
        let paneA = PaneRuntime(isHidden: true)
        let paneB = PaneRuntime(isHidden: true)
        let node = SplitTreeNode.split(
            id: UUID(),
            direction: .horizontal,
            ratio: 0.5,
            left: .leaf(paneA),
            right: .leaf(paneB)
        )
        #expect(node.isEntirelyHidden == true)
    }

    // MARK: 7. visiblePanes on SplitTree

    @Test func visiblePanesExcludesHiddenPanes() {
        let tree = SplitTree()
        let paneA = tree.focusedPane
        let paneB = tree.splitFocusedPane(direction: .horizontal)

        #expect(tree.visiblePanes.count == 2)

        paneB.isHidden = true
        #expect(tree.visiblePanes.count == 1)
        #expect(tree.visiblePanes.first?.id == paneA.id)

        paneB.isHidden = false
        #expect(tree.visiblePanes.count == 2)
    }

    // MARK: 8. showPane restores visibility

    @Test func showPaneRestoresVisibility() {
        let store = AppStateStore()
        let session = store.sessions.first!
        let paneA = session.focusedPane
        _ = session.tree.splitFocusedPane(direction: .horizontal)

        store.hidePane(id: paneA.id)
        #expect(paneA.isHidden == true)

        store.showPane(id: paneA.id)
        #expect(paneA.isHidden == false)
    }

    // MARK: 9. TerminalHostStore placement is driven on hide

    /// Verifies that hidePane drives TerminalHostStore.setPlacement(isVisible:false)
    /// for every tab in the pane, so AppTerminalView.isHidden=true is set even
    /// though TerminalPlaceholderView is unmounted while the pane is hidden.
    ///
    /// AppTerminalView creation requires libghostty and cannot run headlessly,
    /// so we pre-seed a placement via setPlacement and assert it is overwritten
    /// to isVisible=false. The view-hide half (AppTerminalView.isHidden) is
    /// covered by the manual UI sign-off checklist in the issue.
    @Test func hidePaneDrivesHostStorePlacement() {
        let store = AppStateStore()
        let session = store.sessions.first!
        let paneA = session.focusedPane
        _ = session.tree.splitFocusedPane(direction: .horizontal)

        let hostStore = TerminalHostStore.shared
        let tabAID = paneA.activeTabID

        // Pre-seed a visible placement so we can detect the overwrite.
        hostStore.setPlacement(
            TerminalHostStore.Placement(frame: NSRect(x: 0, y: 0, width: 400, height: 300), isVisible: true),
            forTabID: tabAID
        )
        #expect(hostStore.placement(forTabID: tabAID)?.isVisible == true)

        // Hide paneA through the real path.
        store.hidePane(id: paneA.id)
        #expect(paneA.isHidden == true)

        // TerminalHostStore must have been told the placement is no longer visible.
        let placementAfterHide = hostStore.placement(forTabID: tabAID)
        #expect(placementAfterHide != nil)
        #expect(placementAfterHide?.isVisible == false)

        // Verify all tabs in the pane had their placements hidden (multi-tab case).
        for tab in paneA.tabs {
            let p = hostStore.placement(forTabID: tab.id)
            // Tabs that were seeded should be isVisible=false; un-seeded tabs
            // (no prior placement) have p==nil which is also not visible.
            if let p {
                #expect(p.isVisible == false)
            }
        }
    }

    /// After showPane the placement is NOT explicitly driven by WindowRuntime —
    /// TerminalPlaceholderView self-heals on remount. Verify showPane only flips
    /// isHidden and does not leave a stale isVisible=false placement that would
    /// prevent the placeholder from re-showing on remount (the placeholder's
    /// onGeometryChange always overwrites whatever was in the store).
    @Test func showPaneDoesNotBlockPlaceholderSelfHeal() {
        let store = AppStateStore()
        let session = store.sessions.first!
        let paneA = session.focusedPane
        _ = session.tree.splitFocusedPane(direction: .horizontal)

        let hostStore = TerminalHostStore.shared
        let tabAID = paneA.activeTabID

        hostStore.setPlacement(
            TerminalHostStore.Placement(frame: NSRect(x: 0, y: 0, width: 400, height: 300), isVisible: true),
            forTabID: tabAID
        )

        store.hidePane(id: paneA.id)
        #expect(hostStore.placement(forTabID: tabAID)?.isVisible == false)

        store.showPane(id: paneA.id)
        #expect(paneA.isHidden == false)
        // The placement record is still isVisible=false here — TerminalPlaceholderView
        // hasn't remounted yet (we're headless). That is correct: showPane doesn't
        // touch the store; the placeholder fires setPlacement on remount. The test
        // confirms pane.isHidden is flipped so SwiftUI will remount the placeholder.
        // The isVisible=false placement is NOT a blocker — onGeometryChange overwrites it.
        #expect(hostStore.placement(forTabID: tabAID)?.isVisible == false)
    }

    // MARK: 10. Non-terminal pane hide must not leak a placement (#0315 review round 1, finding 1)

    /// A non-terminal pane's `tabs` holds one structural placeholder
    /// `TabRuntime` that never mounts a `TerminalPlaceholderView`, so it
    /// never registers a `TerminalHostStore.terminalViews` entry.
    /// `hidePane`'s per-tab `setPlacement` loop must skip it — writing a
    /// `placements` entry anyway would be a dead entry `releaseTerminalView`
    /// can never clean up (its no-registered-view guard returns before
    /// reaching `placements.removeValue`), leaking one entry per
    /// open→hide→close cycle for the app's lifetime — the #0285
    /// unbounded-growth class.
    @Test func hidingANonTerminalPaneDoesNotLeakATerminalHostStorePlacement() {
        let store = AppStateStore()
        let session = store.sessions.first!
        let terminalPane = session.focusedPane
        let nonTerminalPane = session.tree.splitPane(id: terminalPane.id, direction: .horizontal, kind: .gitStatus)!

        let hostStore = TerminalHostStore.shared
        let phantomTabID = nonTerminalPane.activeTabID
        #expect(hostStore.placement(forTabID: phantomTabID) == nil)

        store.hidePane(id: nonTerminalPane.id)

        #expect(nonTerminalPane.isHidden == true)
        #expect(hostStore.placement(forTabID: phantomTabID) == nil)
    }
}
