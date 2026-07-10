// SplitTreePanePositionTests.swift

import Foundation
import Testing
@testable import BattyKit

@MainActor
struct SplitTreePanePositionTests {

    // MARK: - Canonical shapes (#0259 Verification expectations)

    @Test func singlePaneIsOneOne() {
        let tree = SplitTree()
        let pane = tree.focusedPane

        #expect(tree.panePositions[pane.id]?.label == "1/1")
    }

    @Test func horizontalSplitIsColumnsAcross() {
        let tree = SplitTree()
        let paneA = tree.focusedPane
        tree.splitFocusedPane(direction: .horizontal)
        let paneB = tree.allPanes.first { $0.id != paneA.id }!

        #expect(tree.panePositions[paneA.id]?.label == "1/1")
        #expect(tree.panePositions[paneB.id]?.label == "2/1")
    }

    @Test func verticalSplitsAreRowsDownAColumn() {
        let tree = SplitTree()
        let paneA = tree.focusedPane
        tree.splitFocusedPane(direction: .vertical)
        let paneB = tree.allPanes.first { $0.id != paneA.id }!

        tree.focusedPaneID = paneA.id
        tree.splitFocusedPane(direction: .vertical)
        let paneC = tree.allPanes.first { $0.id != paneA.id && $0.id != paneB.id }!

        #expect(tree.panePositions[paneA.id]?.label == "1/1")
        #expect(tree.panePositions[paneC.id]?.label == "1/2")
        #expect(tree.panePositions[paneB.id]?.label == "1/3")
    }

    /// The exact layout from the issue description: one horizontal split,
    /// then two vertical splits inside the left column.
    /// Expected: 1/1, 1/2, 1/3, 2/1.
    @Test func horizontalThenVerticalChainInLeftColumn() {
        let tree = SplitTree()
        let paneA = tree.focusedPane
        tree.splitFocusedPane(direction: .horizontal)
        let paneD = tree.allPanes.first { $0.id != paneA.id }!

        tree.focusedPaneID = paneA.id
        tree.splitFocusedPane(direction: .vertical)
        let paneB = tree.allPanes.first { ![paneA.id, paneD.id].contains($0.id) }!

        tree.focusedPaneID = paneA.id
        tree.splitFocusedPane(direction: .vertical)
        let paneC = tree.allPanes.first { ![paneA.id, paneB.id, paneD.id].contains($0.id) }!

        let positions = tree.panePositions
        #expect(positions[paneA.id]?.label == "1/1")
        #expect(positions[paneC.id]?.label == "1/2")
        #expect(positions[paneB.id]?.label == "1/3")
        #expect(positions[paneD.id]?.label == "2/1")
    }

    // MARK: - Hidden panes keep their slot (#0256)

    @Test func positionIsStableWhenPaneIsHidden() {
        let tree = SplitTree()
        let paneA = tree.focusedPane
        tree.splitFocusedPane(direction: .horizontal)
        let paneB = tree.allPanes.first { $0.id != paneA.id }!

        let before = tree.panePositions[paneB.id]
        paneB.isHidden = true
        let after = tree.panePositions[paneB.id]

        #expect(before == after)
        #expect(after?.label == "2/1")
        // The neighbor's coordinates are untouched by a sibling's visibility.
        #expect(tree.panePositions[paneA.id]?.label == "1/1")
    }

    // MARK: - Correctness after close / swap

    @Test func positionsRecomputeAfterClose() {
        let tree = SplitTree()
        let paneA = tree.focusedPane
        tree.splitFocusedPane(direction: .horizontal)
        let paneB = tree.allPanes.first { $0.id != paneA.id }!

        tree.focusedPaneID = paneB.id
        tree.splitFocusedPane(direction: .horizontal)
        let paneC = tree.allPanes.first { $0.id != paneA.id && $0.id != paneB.id }!
        #expect(tree.panePositions[paneC.id]?.label == "3/1")

        // Close B: C slides into the second column slot.
        tree.focusedPaneID = paneB.id
        tree.removeFocusedPane()

        #expect(tree.allPanes.contains { $0.id == paneB.id } == false)
        #expect(tree.panePositions[paneA.id]?.label == "1/1")
        #expect(tree.panePositions[paneC.id]?.label == "2/1")
    }

    @Test func positionsFollowTheSlotAfterSwap() {
        let tree = SplitTree()
        let paneA = tree.focusedPane
        tree.splitFocusedPane(direction: .horizontal)
        let paneB = tree.allPanes.first { $0.id != paneA.id }!

        #expect(tree.panePositions[paneA.id]?.label == "1/1")
        #expect(tree.panePositions[paneB.id]?.label == "2/1")

        tree.swapPanes(id: paneA.id, with: paneB.id)

        // Position describes the slot, not the pane identity: after the
        // swap each pane now reports the coordinates of where it moved to.
        #expect(tree.panePositions[paneA.id]?.label == "2/1")
        #expect(tree.panePositions[paneB.id]?.label == "1/1")
    }

    // MARK: - Mixed nesting (Open Questions + review finding 1)

    /// A horizontal split nested inside a vertical row: row 2 is itself
    /// split into two columns. The nested sub-grid gets its own columns
    /// within the outer rectangle rather than crashing or colliding
    /// coordinates.
    @Test func horizontalSplitNestedInsideVerticalRowGetsSubColumns() {
        let tree = SplitTree()
        let paneA = tree.focusedPane
        tree.splitFocusedPane(direction: .vertical)
        let paneB = tree.allPanes.first { $0.id != paneA.id }!

        tree.focusedPaneID = paneB.id
        tree.splitFocusedPane(direction: .horizontal)
        let paneC = tree.allPanes.first { $0.id != paneA.id && $0.id != paneB.id }!

        let positions = tree.panePositions
        #expect(positions[paneA.id]?.label == "1/1")
        #expect(positions[paneB.id]?.label == "1/2")
        #expect(positions[paneC.id]?.label == "2/2")
    }

    /// Review finding 1's repro — three ordinary splits producing
    /// `horizontal(vertical(horizontal(A,B), C), D)`. The left subtree
    /// spans two columns, so span reservation places D at column 3; the
    /// slot-anchored derivation this replaced collided D with B at 2/1.
    @Test func nestedSubgridReservesItsColumnSpanInTheOuterGrid() {
        let tree = SplitTree()
        let paneA = tree.focusedPane
        tree.splitFocusedPane(direction: .horizontal)
        let paneD = tree.allPanes.first { $0.id != paneA.id }!

        tree.focusedPaneID = paneA.id
        tree.splitFocusedPane(direction: .vertical)
        let paneC = tree.allPanes.first { ![paneA.id, paneD.id].contains($0.id) }!

        tree.focusedPaneID = paneA.id
        tree.splitFocusedPane(direction: .horizontal)
        let paneB = tree.allPanes.first { ![paneA.id, paneC.id, paneD.id].contains($0.id) }!

        let positions = tree.panePositions
        #expect(positions[paneA.id]?.label == "1/1")
        #expect(positions[paneB.id]?.label == "2/1")
        #expect(positions[paneC.id]?.label == "1/2")
        #expect(positions[paneD.id]?.label == "3/1")
        #expect(Set(positions.values).count == positions.count)
    }

    /// Row-axis mirror of the span-reservation rule with nesting on both
    /// arms of the outer split: `vertical(horizontal(A, vertical(B,C)),
    /// horizontal(D,E))`. Row 1 spans two rows (the B/C stack), so the
    /// outer second row starts at row 3 — without row-span reservation,
    /// C and E would both land at 2/2.
    @Test func nestedSubgridReservesItsRowSpanInTheOuterGrid() {
        let tree = SplitTree()
        let paneA = tree.focusedPane
        tree.splitFocusedPane(direction: .vertical)
        let paneD = tree.allPanes.first { $0.id != paneA.id }!

        tree.focusedPaneID = paneA.id
        tree.splitFocusedPane(direction: .horizontal)
        let paneB = tree.allPanes.first { ![paneA.id, paneD.id].contains($0.id) }!

        tree.focusedPaneID = paneB.id
        tree.splitFocusedPane(direction: .vertical)
        let paneC = tree.allPanes.first { ![paneA.id, paneB.id, paneD.id].contains($0.id) }!

        tree.focusedPaneID = paneD.id
        tree.splitFocusedPane(direction: .horizontal)
        let paneE = tree.allPanes.first { ![paneA.id, paneB.id, paneC.id, paneD.id].contains($0.id) }!

        let positions = tree.panePositions
        #expect(positions[paneA.id]?.label == "1/1")
        #expect(positions[paneB.id]?.label == "2/1")
        #expect(positions[paneC.id]?.label == "2/2")
        #expect(positions[paneD.id]?.label == "1/3")
        #expect(positions[paneE.id]?.label == "2/3")
        #expect(Set(positions.values).count == positions.count)
    }

    // MARK: - Root-level full-dimension wrap (#0262)

    /// Option-Cmd-D: the new pane becomes a trailing full-height column,
    /// landing one column past whatever the existing tree already spans —
    /// the same "2/1" slot a plain horizontal split of a lone pane would
    /// produce, since a full-dimension wrap and an ordinary split of a
    /// single-pane tree are the same shape.
    @Test func fullDimensionHorizontalWrapAddsATrailingColumn() {
        let tree = SplitTree()
        let paneA = tree.focusedPane
        tree.splitFocusedPane(direction: .vertical)
        let paneB = tree.allPanes.first { $0.id != paneA.id }!

        let paneC = tree.splitFullDimension(direction: .horizontal)

        let positions = tree.panePositions
        #expect(positions[paneA.id]?.label == "1/1")
        #expect(positions[paneB.id]?.label == "1/2")
        #expect(positions[paneC.id]?.label == "2/1")
        #expect(Set(positions.values).count == positions.count)
    }

    /// Option-Shift-Cmd-D: the new pane becomes a trailing full-width row,
    /// landing one row past whatever the existing tree already spans.
    @Test func fullDimensionVerticalWrapAddsATrailingRow() {
        let tree = SplitTree()
        let paneA = tree.focusedPane
        tree.splitFocusedPane(direction: .horizontal)
        let paneB = tree.allPanes.first { $0.id != paneA.id }!

        let paneC = tree.splitFullDimension(direction: .vertical)

        let positions = tree.panePositions
        #expect(positions[paneA.id]?.label == "1/1")
        #expect(positions[paneB.id]?.label == "2/1")
        #expect(positions[paneC.id]?.label == "1/2")
        #expect(Set(positions.values).count == positions.count)
    }

    // MARK: - Every pane gets a unique position

    private func expectUniquePositions(in tree: SplitTree) {
        let positions = tree.panePositions
        #expect(positions.count == tree.allPanes.count)
        #expect(Set(positions.values).count == positions.count)
    }

    @Test func everyPaneHasAUniquePosition() {
        // Layout 1: columns of rows (the canonical shape).
        let canonical = SplitTree()
        let cA = canonical.focusedPane
        canonical.splitFocusedPane(direction: .horizontal)
        canonical.focusedPaneID = cA.id
        canonical.splitFocusedPane(direction: .vertical)
        let cD = canonical.allPanes.first { $0.id != cA.id }!
        canonical.focusedPaneID = cD.id
        canonical.splitFocusedPane(direction: .horizontal)
        expectUniquePositions(in: canonical)

        // Layout 2: review finding 1's colliding repro —
        // horizontal(vertical(horizontal(A,B), C), D).
        let repro = SplitTree()
        let rA = repro.focusedPane
        repro.splitFocusedPane(direction: .horizontal)
        repro.focusedPaneID = rA.id
        repro.splitFocusedPane(direction: .vertical)
        repro.focusedPaneID = rA.id
        repro.splitFocusedPane(direction: .horizontal)
        expectUniquePositions(in: repro)

        // Layout 3: deep alternation — keep splitting the same pane with
        // alternating directions so every level nests a perpendicular
        // sub-grid inside the previous one.
        let alternating = SplitTree()
        let aA = alternating.focusedPane
        for depth in 0..<6 {
            alternating.focusedPaneID = aA.id
            alternating.splitFocusedPane(
                direction: depth.isMultiple(of: 2) ? .horizontal : .vertical
            )
        }
        expectUniquePositions(in: alternating)

        // Layout 4: nesting on both arms of the outer split (the row-span
        // variant), then one more split inside a nested grid.
        let bothArms = SplitTree()
        let bA = bothArms.focusedPane
        bothArms.splitFocusedPane(direction: .vertical)
        let bD = bothArms.allPanes.first { $0.id != bA.id }!
        bothArms.focusedPaneID = bA.id
        bothArms.splitFocusedPane(direction: .horizontal)
        let bB = bothArms.allPanes.first { ![bA.id, bD.id].contains($0.id) }!
        bothArms.focusedPaneID = bB.id
        bothArms.splitFocusedPane(direction: .vertical)
        bothArms.focusedPaneID = bD.id
        let bE = bothArms.splitFocusedPane(direction: .horizontal)
        bothArms.focusedPaneID = bE.id
        bothArms.splitFocusedPane(direction: .vertical)
        expectUniquePositions(in: bothArms)
    }

    // MARK: - Column-major sort for the sidebar pane list (#0263)

    /// The exact repro from the issue: split A horizontally (B lands beside
    /// it at 2/1), then split A vertically (C lands below it at 1/2). The
    /// tree is `horizontal(vertical(A, C), B)`; tree-traversal order
    /// (`allPanes`) is A, C, B. Column-major order must keep column 1's
    /// stacked pair together before column 2: A (1/1), C (1/2), B (2/1).
    @Test func columnMajorSortMatchesIssueRepro() {
        let tree = SplitTree()
        let paneA = tree.focusedPane
        tree.splitFocusedPane(direction: .horizontal)
        let paneB = tree.allPanes.first { $0.id != paneA.id }!

        tree.focusedPaneID = paneA.id
        tree.splitFocusedPane(direction: .vertical)
        let paneC = tree.allPanes.first { ![paneA.id, paneB.id].contains($0.id) }!

        #expect(tree.panePositions[paneA.id]?.label == "1/1")
        #expect(tree.panePositions[paneB.id]?.label == "2/1")
        #expect(tree.panePositions[paneC.id]?.label == "1/2")

        // Sanity check: allPanes is tree-traversal order, which happens to
        // already match column-major order for this particular shape.
        #expect(tree.allPanes.map(\.id) == [paneA.id, paneC.id, paneB.id])

        #expect(tree.panesSortedByColumnThenRow.map(\.id) == [paneA.id, paneC.id, paneB.id])
    }

    /// Span-reservation repro (review finding 1): A (1/1), B (2/1), C
    /// (1/2), D (3/1). Column-major must keep column 1's stacked pair (A,
    /// C) together before column 2 (B) and column 3 (D).
    @Test func columnMajorSortHandlesColumnSpanReservation() {
        let tree = SplitTree()
        let paneA = tree.focusedPane
        tree.splitFocusedPane(direction: .horizontal)
        let paneD = tree.allPanes.first { $0.id != paneA.id }!

        tree.focusedPaneID = paneA.id
        tree.splitFocusedPane(direction: .vertical)
        let paneC = tree.allPanes.first { ![paneA.id, paneD.id].contains($0.id) }!

        tree.focusedPaneID = paneA.id
        tree.splitFocusedPane(direction: .horizontal)
        let paneB = tree.allPanes.first { ![paneA.id, paneC.id, paneD.id].contains($0.id) }!

        #expect(tree.panesSortedByColumnThenRow.map(\.id) == [paneA.id, paneC.id, paneB.id, paneD.id])
    }

    /// A single row of three panes (A 1/1, B 2/1, C 3/1, built by chaining
    /// horizontal splits) has one pane per column, so column-major order
    /// equals the already-correct left-to-right order — this guards against
    /// a sort that accidentally scrambles an already-correct order.
    @Test func columnMajorSortIsNoOpWhenAlreadyColumnMajor() {
        let tree = SplitTree()
        let paneA = tree.focusedPane
        tree.splitFocusedPane(direction: .horizontal)
        let paneB = tree.allPanes.first { $0.id != paneA.id }!

        tree.focusedPaneID = paneB.id
        tree.splitFocusedPane(direction: .horizontal)
        let paneC = tree.allPanes.first { ![paneA.id, paneB.id].contains($0.id) }!

        #expect(tree.panePositions[paneA.id]?.label == "1/1")
        #expect(tree.panePositions[paneB.id]?.label == "2/1")
        #expect(tree.panePositions[paneC.id]?.label == "3/1")

        #expect(tree.allPanes.map(\.id) == [paneA.id, paneB.id, paneC.id])
        #expect(tree.panesSortedByColumnThenRow.map(\.id) == [paneA.id, paneB.id, paneC.id])
    }

    /// Hidden panes (#0256) keep their tree slot and must stay in the
    /// column-major order at that slot — hiding a pane doesn't remove it
    /// from the sidebar list, only from rendering.
    @Test func columnMajorSortIncludesHiddenPanesAtTheirSlot() {
        let tree = SplitTree()
        let paneA = tree.focusedPane
        tree.splitFocusedPane(direction: .horizontal)
        let paneB = tree.allPanes.first { $0.id != paneA.id }!

        tree.focusedPaneID = paneA.id
        tree.splitFocusedPane(direction: .vertical)
        let paneC = tree.allPanes.first { ![paneA.id, paneB.id].contains($0.id) }!

        paneB.isHidden = true

        #expect(tree.panesSortedByColumnThenRow.map(\.id) == [paneA.id, paneC.id, paneB.id])
    }

    /// Every pane appears exactly once in the sorted order, across the same
    /// varied layouts `everyPaneHasAUniquePosition` exercises.
    @Test func columnMajorSortContainsEveryPaneExactlyOnce() {
        let tree = SplitTree()
        let aA = tree.focusedPane
        for depth in 0..<6 {
            tree.focusedPaneID = aA.id
            tree.splitFocusedPane(direction: depth.isMultiple(of: 2) ? .horizontal : .vertical)
        }

        let sorted = tree.panesSortedByColumnThenRow
        #expect(sorted.count == tree.allPanes.count)
        #expect(Set(sorted.map(\.id)) == Set(tree.allPanes.map(\.id)))
    }
}
