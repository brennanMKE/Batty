// SplitTreeEqualizationTests.swift

import Foundation
import Testing
@testable import BattyKit

@MainActor
struct SplitTreeEqualizationTests {

    // Walk the tree to compute the effective rendered fraction for a leaf pane.
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

    // MARK: - Same-axis splits equalize

    @Test func twoHorizontalPanesAreEqualHalves() {
        let tree = SplitTree()
        let paneA = tree.focusedPane
        tree.splitFocusedPane(direction: .horizontal)
        let paneB = tree.allPanes.first { $0.id != paneA.id }!

        #expect(isApprox(fraction(of: paneA.id, in: tree.root)!, 0.5))
        #expect(isApprox(fraction(of: paneB.id, in: tree.root)!, 0.5))
    }

    @Test func thirdHorizontalPaneEqualizesToThirds() {
        let tree = SplitTree()
        let paneA = tree.focusedPane
        tree.splitFocusedPane(direction: .horizontal)
        let paneB = tree.allPanes.first { $0.id != paneA.id }!

        // Add a third pane adjacent to A along the same axis
        tree.focusedPaneID = paneA.id
        tree.splitFocusedPane(direction: .horizontal)
        let paneC = tree.allPanes.first { $0.id != paneA.id && $0.id != paneB.id }!

        #expect(isApprox(fraction(of: paneA.id, in: tree.root)!, 1.0 / 3.0))
        #expect(isApprox(fraction(of: paneB.id, in: tree.root)!, 1.0 / 3.0))
        #expect(isApprox(fraction(of: paneC.id, in: tree.root)!, 1.0 / 3.0))
    }

    @Test func fourthHorizontalPaneEqualizesToQuarters() {
        let tree = SplitTree()
        let paneA = tree.focusedPane
        tree.splitFocusedPane(direction: .horizontal)
        let paneB = tree.allPanes.first { $0.id != paneA.id }!

        tree.focusedPaneID = paneA.id
        tree.splitFocusedPane(direction: .horizontal)
        let paneC = tree.allPanes.first { $0.id != paneA.id && $0.id != paneB.id }!

        // Add a fourth pane adjacent to B
        tree.focusedPaneID = paneB.id
        tree.splitFocusedPane(direction: .horizontal)
        let paneD = tree.allPanes.first { $0.id != paneA.id && $0.id != paneB.id && $0.id != paneC.id }!

        #expect(isApprox(fraction(of: paneA.id, in: tree.root)!, 0.25))
        #expect(isApprox(fraction(of: paneB.id, in: tree.root)!, 0.25))
        #expect(isApprox(fraction(of: paneC.id, in: tree.root)!, 0.25))
        #expect(isApprox(fraction(of: paneD.id, in: tree.root)!, 0.25))
    }

    @Test func threeVerticalPanesEqualize() {
        let tree = SplitTree()
        let paneA = tree.focusedPane
        tree.splitFocusedPane(direction: .vertical)
        let paneB = tree.allPanes.first { $0.id != paneA.id }!

        tree.focusedPaneID = paneA.id
        tree.splitFocusedPane(direction: .vertical)
        let paneC = tree.allPanes.first { $0.id != paneA.id && $0.id != paneB.id }!

        #expect(isApprox(fraction(of: paneA.id, in: tree.root)!, 1.0 / 3.0))
        #expect(isApprox(fraction(of: paneB.id, in: tree.root)!, 1.0 / 3.0))
        #expect(isApprox(fraction(of: paneC.id, in: tree.root)!, 1.0 / 3.0))
    }

    // MARK: - Perpendicular split starts a new axis (50/50 within sub-region, H-chain unchanged)

    @Test func perpendicularSplitDoesNotRebalanceOtherAxis() {
        let tree = SplitTree()
        let paneA = tree.focusedPane
        tree.splitFocusedPane(direction: .horizontal)
        let paneB = tree.allPanes.first { $0.id != paneA.id }!
        // [A | B] — 50/50 horizontal

        // Split A vertically → C. This starts a new V-axis inside A's half; the H-chain is not widened.
        tree.focusedPaneID = paneA.id
        tree.splitFocusedPane(direction: .vertical)
        let paneC = tree.allPanes.first { $0.id != paneA.id && $0.id != paneB.id }!

        // B still owns 50% of horizontal width — the H-chain was NOT rebalanced for a V split.
        #expect(isApprox(fraction(of: paneB.id, in: tree.root)!, 0.5))
        // A and C share A's original 50% vertically → each gets 25% of total.
        #expect(isApprox(fraction(of: paneA.id, in: tree.root)!, 0.25))
        #expect(isApprox(fraction(of: paneC.id, in: tree.root)!, 0.25))
    }

    @Test func perpendicularSplitIsItself5050WithinItsRegion() {
        let tree = SplitTree()
        let paneA = tree.focusedPane
        // A single pane, split vertically — the new V-chain starts at 50/50.
        tree.splitFocusedPane(direction: .vertical)
        let paneB = tree.allPanes.first { $0.id != paneA.id }!

        #expect(isApprox(fraction(of: paneA.id, in: tree.root)!, 0.5))
        #expect(isApprox(fraction(of: paneB.id, in: tree.root)!, 0.5))
    }

    // MARK: - Split after manual resize re-equalizes

    @Test func splitAfterManualResizeEqualizes() {
        let tree = SplitTree()
        let paneA = tree.focusedPane
        tree.splitFocusedPane(direction: .horizontal)
        let paneB = tree.allPanes.first { $0.id != paneA.id }!

        // Simulate a drag-resize: manually set the split ratio to 70/30.
        if case .split(let splitID, _, _, _, _) = tree.root {
            tree.updateRatio(forSplitID: splitID, to: 0.7)
        }
        #expect(!isApprox(fraction(of: paneA.id, in: tree.root)!, 0.5), "resize must have taken effect")

        // Now split A horizontally → C. The whole H-chain should equalize to 1/3 each,
        // discarding the 70/30 manual ratio.
        tree.focusedPaneID = paneA.id
        tree.splitFocusedPane(direction: .horizontal)
        let paneC = tree.allPanes.first { $0.id != paneA.id && $0.id != paneB.id }!

        #expect(isApprox(fraction(of: paneA.id, in: tree.root)!, 1.0 / 3.0))
        #expect(isApprox(fraction(of: paneB.id, in: tree.root)!, 1.0 / 3.0))
        #expect(isApprox(fraction(of: paneC.id, in: tree.root)!, 1.0 / 3.0))
    }

    // MARK: - Perpendicular sub-chain inside a same-direction chain

    @Test func sameAxisSplitAdjacentToPerpendicularSubtreeCountsAsOneUnit() {
        // Build: [split(V, A, B) | C] — two horizontal units, left is a V-subtree
        let tree = SplitTree()
        let paneA = tree.focusedPane
        // Step 1: split A vertically → B
        tree.splitFocusedPane(direction: .vertical)
        let paneB = tree.allPanes.first { $0.id != paneA.id }!
        // Tree: split(V, A, B). V-chain has 2 leaves → 50/50.

        // Step 2: split B horizontally → C. A new H-axis starts here.
        // Because the parent of B is a V-split (different direction), this is a new H-chain.
        tree.focusedPaneID = paneB.id
        tree.splitFocusedPane(direction: .horizontal)
        let paneC = tree.allPanes.first { $0.id != paneA.id && $0.id != paneB.id }!
        // Tree: split(V, 0.5, A, split(H, 0.5, B, C))
        // The H-chain containing C is just split(H, B, C) — 2 H-leaves → 50/50.
        // The outer V-chain is NOT rebalanced (we only did H).

        // V-chain: A and B/C-region are 50/50 vertically
        // A gets 50% of vertical.
        #expect(isApprox(fraction(of: paneA.id, in: tree.root)!, 0.5))
        // B and C share the bottom 50% horizontally → each gets 25%.
        #expect(isApprox(fraction(of: paneB.id, in: tree.root)!, 0.25))
        #expect(isApprox(fraction(of: paneC.id, in: tree.root)!, 0.25))
    }

    // A perpendicular subtree that is a *member* of a rebalanced chain must be
    // counted as ONE unit (not by its leaf count), so it gets 1/n of the axis.
    @Test func perpendicularSubtreeCountedAsOneUnitDuringRebalance() {
        let tree = SplitTree()
        let paneA = tree.focusedPane
        tree.splitFocusedPane(direction: .horizontal)      // [A | B], 50/50
        let paneB = tree.allPanes.first { $0.id != paneA.id }!

        // Turn A into a vertical subtree (A / C). H-chain is still [(A/C) | B], 50/50.
        tree.focusedPaneID = paneA.id
        tree.splitFocusedPane(direction: .vertical)
        let paneC = tree.allPanes.first { ![paneA.id, paneB.id].contains($0.id) }!

        // Now grow the H-chain: split B horizontally → D. The chain is now three
        // units — [(A/C)-subtree | B | D] — and must equalize to 1/3 WIDTH each.
        tree.focusedPaneID = paneB.id
        tree.splitFocusedPane(direction: .horizontal)
        let paneD = tree.allPanes.first { ![paneA.id, paneB.id, paneC.id].contains($0.id) }!

        // If the V-subtree were (wrongly) counted by its 2 leaves it would take
        // 2/4 = 1/2 the width. Correct: 1/3 width, split 50/50 vertically →
        // A and C each 1/3 × 1/2 = 1/6 area; B and D each 1/3.
        #expect(isApprox(fraction(of: paneA.id, in: tree.root)!, 1.0 / 6.0))
        #expect(isApprox(fraction(of: paneC.id, in: tree.root)!, 1.0 / 6.0))
        #expect(isApprox(fraction(of: paneB.id, in: tree.root)!, 1.0 / 3.0))
        #expect(isApprox(fraction(of: paneD.id, in: tree.root)!, 1.0 / 3.0))
    }

    // Deep mixed tree: a new pane added in an INNER same-direction split that sits
    // below a perpendicular break must NOT rebalance the OUTER same-direction chain
    // (exercises the `.foundBelowBreak` outer-chain-preserved path).
    @Test func innerSameAxisSplitBelowPerpendicularBreakPreservesOuterChain() {
        let tree = SplitTree()
        let paneA = tree.focusedPane
        tree.splitFocusedPane(direction: .horizontal)      // root H-chain [A | B], 50/50
        let paneB = tree.allPanes.first { $0.id != paneA.id }!

        // Split B vertically → (B / E). Root H-chain [A | (B/E)] stays 50/50.
        tree.focusedPaneID = paneB.id
        tree.splitFocusedPane(direction: .vertical)
        let paneE = tree.allPanes.first { ![paneA.id, paneB.id].contains($0.id) }!

        // Split B horizontally → C, forming an INNER H-chain [B | C] below the V break.
        tree.focusedPaneID = paneB.id
        tree.splitFocusedPane(direction: .horizontal)
        let paneC = tree.allPanes.first { ![paneA.id, paneB.id, paneE.id].contains($0.id) }!

        // The OUTER root H-chain must be untouched: A keeps 1/2 the width (NOT 1/3).
        #expect(isApprox(fraction(of: paneA.id, in: tree.root)!, 0.5))
        // Right half (0.5) splits V into [ (B|C) | E ] at 50/50 → E = 0.5 × 0.5 = 0.25.
        #expect(isApprox(fraction(of: paneE.id, in: tree.root)!, 0.25))
        // Inner H-chain [B|C] splits its 0.5×0.5 region 50/50 → each 0.125.
        #expect(isApprox(fraction(of: paneB.id, in: tree.root)!, 0.125))
        #expect(isApprox(fraction(of: paneC.id, in: tree.root)!, 0.125))
    }
}
