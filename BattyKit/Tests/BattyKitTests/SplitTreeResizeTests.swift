// SplitTreeResizeTests.swift

import Foundation
import Testing
@testable import BattyKit

/// Covers `SplitTree.resizeFocusedSplit(_:)` (#0325) — the model-level
/// engine behind Cmd-Ctrl-arrows. Exercises the real ratio math against a
/// real `SplitTree`, not just that the `ShortcutAction` cases exist.
@MainActor
struct SplitTreeResizeTests {

    // Walk the tree to compute the effective rendered fraction for a leaf pane.
    // Mirrors SplitTreeEqualizationTests' helper.
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

    // MARK: - Step direction

    @Test func leftArrowGrowsTheFocusedPaneWhenItIsTheRightChild() {
        // [A | B], focus B (the right half) — matches PRD.md §6.4 "Panes &
        // splits" / the #0325 worked example: Cmd-Ctrl-Left on a pane in the
        // right half grows it, because the divider moves left, away from B,
        // toward A.
        let tree = SplitTree()
        let paneA = tree.focusedPane
        tree.splitFocusedPane(direction: .horizontal)
        let paneB = tree.allPanes.first { $0.id != paneA.id }!
        #expect(tree.focusedPaneID == paneB.id)

        tree.resizeFocusedSplit(.left)

        #expect(isApprox(fraction(of: paneB.id, in: tree.root)!, 0.55))
        #expect(isApprox(fraction(of: paneA.id, in: tree.root)!, 0.45))
    }

    @Test func leftArrowShrinksTheFocusedPaneWhenItIsTheLeftChild() {
        // [A | B], focus A (the left half) — the same key, opposite side:
        // the divider still moves left, but that's now toward the focused
        // pane's own edge, shrinking it.
        let tree = SplitTree()
        let paneA = tree.focusedPane
        tree.splitFocusedPane(direction: .horizontal)
        tree.focusedPaneID = paneA.id

        tree.resizeFocusedSplit(.left)

        #expect(isApprox(fraction(of: paneA.id, in: tree.root)!, 0.45))
    }

    @Test func rightArrowGrowsTheLeftChildAndShrinksTheRightChild() {
        let tree = SplitTree()
        let paneA = tree.focusedPane
        tree.splitFocusedPane(direction: .horizontal)
        let paneB = tree.allPanes.first { $0.id != paneA.id }!
        tree.focusedPaneID = paneA.id

        tree.resizeFocusedSplit(.right)

        #expect(isApprox(fraction(of: paneA.id, in: tree.root)!, 0.55))
        #expect(isApprox(fraction(of: paneB.id, in: tree.root)!, 0.45))
    }

    @Test func upAndDownResizeAVerticalSplitBySameStep() {
        // [A / B] stacked, focus B (bottom half). Up moves the divider up,
        // toward A, growing B — the vertical mirror of the left/right case.
        let upTree = SplitTree()
        let upPaneA = upTree.focusedPane
        upTree.splitFocusedPane(direction: .vertical)
        let upPaneB = upTree.allPanes.first { $0.id != upPaneA.id }!
        #expect(upTree.focusedPaneID == upPaneB.id)

        upTree.resizeFocusedSplit(.up)

        #expect(isApprox(fraction(of: upPaneB.id, in: upTree.root)!, 0.55))
        #expect(isApprox(fraction(of: upPaneA.id, in: upTree.root)!, 0.45))

        // Down is the mirror: from a fresh split, focus the bottom half and
        // press Down — the divider moves down, toward the focused pane's own
        // edge, shrinking it (same rule as leftArrowShrinks…, vertical axis).
        let downTree = SplitTree()
        let downPaneA = downTree.focusedPane
        downTree.splitFocusedPane(direction: .vertical)
        let downPaneB = downTree.allPanes.first { $0.id != downPaneA.id }!
        #expect(downTree.focusedPaneID == downPaneB.id)

        downTree.resizeFocusedSplit(.down)

        #expect(isApprox(fraction(of: downPaneA.id, in: downTree.root)!, 0.55))
        #expect(isApprox(fraction(of: downPaneB.id, in: downTree.root)!, 0.45))
    }

    // Discriminates a `.down` axis-mapping bug (mapped to `.horizontal`
    // instead of `.vertical`) from a correct implementation: on a tree whose
    // focused pane's immediate parent is a horizontal split nested under an
    // outer vertical split, `.down` must walk past the horizontal parent and
    // resize the outer vertical split — leaving the horizontal split
    // untouched. A `.down` mis-mapped to `.horizontal` would instead resize
    // the *inner* horizontal split immediately (no walk needed) and leave
    // the vertical split untouched — the opposite of what's asserted below.
    @Test func resizeDownOnlyAffectsTheNearestVerticalAncestor() {
        let tree = SplitTree()
        let paneA = tree.focusedPane
        tree.splitFocusedPane(direction: .vertical)
        let paneB = tree.allPanes.first { $0.id != paneA.id }!
        tree.focusedPaneID = paneB.id
        tree.splitFocusedPane(direction: .horizontal)
        let paneC = tree.allPanes.first { ![paneA.id, paneB.id].contains($0.id) }!
        #expect(tree.focusedPaneID == paneC.id)

        guard case let .split(vID, .vertical, vRatioBefore, .leaf(leafA), .split(hID, .horizontal, hRatioBefore, .leaf(leafB), .leaf(leafC))) = tree.root,
              leafA.id == paneA.id, leafB.id == paneB.id, leafC.id == paneC.id else {
            Issue.record("unexpected tree shape: \(tree.root)")
            return
        }

        tree.resizeFocusedSplit(.down)

        #expect(isApprox(tree.root.ratio(forSplitID: hID)!, hRatioBefore), "the perpendicular H-split must be untouched")
        #expect(isApprox(tree.root.ratio(forSplitID: vID)!, vRatioBefore + 0.05), "the outer V-split absorbs the resize")
    }

    @Test func repeatedPressesAccumulateInFivePercentSteps() {
        let tree = SplitTree()
        let paneA = tree.focusedPane
        tree.splitFocusedPane(direction: .horizontal)
        tree.focusedPaneID = paneA.id

        tree.resizeFocusedSplit(.right)
        tree.resizeFocusedSplit(.right)
        tree.resizeFocusedSplit(.right)

        #expect(isApprox(fraction(of: paneA.id, in: tree.root)!, 0.65))
    }

    // MARK: - Ancestor resolution: walk past a perpendicular parent

    @Test func resizeWalksPastAnImmediatePerpendicularParentToTheOuterMatchingAncestor() {
        // Build split(H, A, split(V, B, C)) — C's immediate parent is a
        // V-split, which a left/right arrow cannot act on. The resize must
        // walk up one more level to the outer H-split instead of no-oping.
        let tree = SplitTree()
        let paneA = tree.focusedPane
        tree.splitFocusedPane(direction: .horizontal)
        let paneB = tree.allPanes.first { $0.id != paneA.id }!
        tree.focusedPaneID = paneB.id
        tree.splitFocusedPane(direction: .vertical)
        let paneC = tree.allPanes.first { ![paneA.id, paneB.id].contains($0.id) }!
        #expect(tree.focusedPaneID == paneC.id)

        guard case let .split(hID, .horizontal, hRatioBefore, .leaf(leafA), .split(vID, .vertical, vRatioBefore, .leaf(leafB), .leaf(leafC))) = tree.root,
              leafA.id == paneA.id, leafB.id == paneB.id, leafC.id == paneC.id else {
            Issue.record("unexpected tree shape: \(tree.root)")
            return
        }

        let fractionCBefore = fraction(of: paneC.id, in: tree.root)!

        tree.resizeFocusedSplit(.left)

        #expect(isApprox(tree.root.ratio(forSplitID: vID)!, vRatioBefore), "the perpendicular V-split must be untouched")
        #expect(isApprox(tree.root.ratio(forSplitID: hID)!, hRatioBefore - 0.05), "the outer H-split absorbs the resize")
        // C sits inside the H-split's right (B/C) branch, so growing that
        // branch grows C too.
        #expect(fraction(of: paneC.id, in: tree.root)! > fractionCBefore)
    }

    // MARK: - No matching ancestor: silent no-op

    @Test func singleUnsplitPaneResizeIsANoOp() {
        let tree = SplitTree()
        let before = tree.root
        tree.resizeFocusedSplit(.left)
        tree.resizeFocusedSplit(.right)
        tree.resizeFocusedSplit(.up)
        tree.resizeFocusedSplit(.down)

        guard case .leaf = tree.root, case .leaf = before else {
            Issue.record("expected a single-leaf tree")
            return
        }
        // No split exists at all, so nothing in the tree shape can have changed.
    }

    @Test func leftRightNoOpsWhenEveryAncestorIsVertical() {
        // A three-pane vertical chain has no horizontal split anywhere on
        // the path to any leaf — Cmd-Ctrl-Left/Right must not invent one.
        let tree = SplitTree()
        let paneA = tree.focusedPane
        tree.splitFocusedPane(direction: .vertical)
        let paneB = tree.allPanes.first { $0.id != paneA.id }!
        tree.focusedPaneID = paneA.id
        tree.splitFocusedPane(direction: .vertical)
        let paneC = tree.allPanes.first { ![paneA.id, paneB.id].contains($0.id) }!
        tree.focusedPaneID = paneC.id

        let fractionsBefore = tree.allPanes.map { fraction(of: $0.id, in: tree.root)! }

        tree.resizeFocusedSplit(.left)
        tree.resizeFocusedSplit(.right)

        let fractionsAfter = tree.allPanes.map { fraction(of: $0.id, in: tree.root)! }
        #expect(fractionsBefore == fractionsAfter)
    }

    // MARK: - Clamp

    @Test func resizeClampsAtTheLowerBound() {
        let tree = SplitTree()
        let paneA = tree.focusedPane
        tree.splitFocusedPane(direction: .horizontal)
        tree.focusedPaneID = paneA.id

        for _ in 0..<30 {
            tree.resizeFocusedSplit(.left)
        }

        #expect(isApprox(fraction(of: paneA.id, in: tree.root)!, 0.05))
    }

    @Test func resizeClampsAtTheUpperBound() {
        let tree = SplitTree()
        let paneA = tree.focusedPane
        tree.splitFocusedPane(direction: .horizontal)
        tree.focusedPaneID = paneA.id

        for _ in 0..<30 {
            tree.resizeFocusedSplit(.right)
        }

        #expect(isApprox(fraction(of: paneA.id, in: tree.root)!, 0.95))
    }
}
