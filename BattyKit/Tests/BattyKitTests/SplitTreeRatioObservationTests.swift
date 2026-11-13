// SplitTreeRatioObservationTests.swift

import Foundation
import Observation
import Testing
@testable import BattyKit

private nonisolated final class RatioNotifiedFlag: @unchecked Sendable {
    var fired = false
}

@MainActor
struct SplitTreeRatioObservationTests {
    private func makeTwoPaneTree() -> (SplitTree, UUID, PaneRuntime, PaneRuntime) {
        let tree = SplitTree()
        let a = tree.focusedPane
        let b = tree.splitFocusedPane(direction: .horizontal)
        guard case .split(let id, _, _, _, _) = tree.root else {
            Issue.record("expected a split root")
            return (tree, UUID(), a, b)
        }
        return (tree, id, a, b)
    }

    private func trackStructure(_ tree: SplitTree) -> RatioNotifiedFlag {
        let flag = RatioNotifiedFlag()
        withObservationTracking {
            _ = tree.root
            _ = tree.allPanes
            _ = tree.visiblePanes
            _ = tree.panePositions
            _ = tree.panesSortedByColumnThenRow
        } onChange: { flag.fired = true }
        return flag
    }

    @Test func ratioChangeDoesNotNotifyStructureReaders() {
        let (tree, id, _, _) = makeTwoPaneTree()
        let structure = trackStructure(tree)
        tree.updateRatio(forSplitID: id, to: 0.7)
        #expect(structure.fired == false)
        #expect(tree.root.ratio(forSplitID: id) == 0.7)
    }

    private func trackRatio(_ box: SplitRatio) -> RatioNotifiedFlag {
        let flag = RatioNotifiedFlag()
        withObservationTracking { _ = box.value } onChange: { flag.fired = true }
        return flag
    }

    private func fraction(of paneID: UUID, in node: SplitTreeNode, available: Double = 1.0) -> Double? {
        switch node {
        case .leaf(let pane):
            return pane.id == paneID ? available : nil
        case .split(_, _, let ratio, let left, let right):
            return fraction(of: paneID, in: left, available: available * ratio.value)
                ?? fraction(of: paneID, in: right, available: available * (1.0 - ratio.value))
        }
    }

    @Test func ratioChangeNotifiesTheRatioReader() throws {
        let (tree, id, _, _) = makeTwoPaneTree()
        let box = try #require(tree.root.ratioBox(forSplitID: id))
        let ratio = trackRatio(box)
        tree.updateRatio(forSplitID: id, to: 0.7)
        #expect(ratio.fired)
    }

    @Test func clampedEqualRatioWriteDoesNotNotify() throws {
        let (tree, id, _, _) = makeTwoPaneTree()
        tree.updateRatio(forSplitID: id, to: 0.95)
        let box = try #require(tree.root.ratioBox(forSplitID: id))
        let structure = trackStructure(tree)
        let ratio = trackRatio(box)
        tree.updateRatio(forSplitID: id, to: 0.99)
        tree.updateRatio(forSplitID: id, to: 0.95)
        #expect(structure.fired == false)
        #expect(ratio.fired == false)
        #expect(tree.root.ratio(forSplitID: id) == 0.95)
    }

    @Test func keyboardResizeDoesNotNotifyStructureReaders() {
        let (tree, id, _, b) = makeTwoPaneTree()
        tree.focusedPaneID = b.id
        let structure = trackStructure(tree)
        tree.resizeFocusedSplit(.left)
        #expect(structure.fired == false)
        let value = tree.root.ratio(forSplitID: id) ?? 0
        #expect(abs(value - 0.45) < 1e-9)
    }

    @Test func unknownSplitIDIsANoOp() throws {
        let (tree, id, _, _) = makeTwoPaneTree()
        let box = try #require(tree.root.ratioBox(forSplitID: id))
        let structure = trackStructure(tree)
        let ratio = trackRatio(box)
        tree.updateRatio(forSplitID: UUID(), to: 0.3)
        #expect(structure.fired == false)
        #expect(ratio.fired == false)
    }

    @Test func structuralEditStillNotifiesStructureReaders() {
        let (tree, _, _, b) = makeTwoPaneTree()
        let afterSplit = trackStructure(tree)
        _ = tree.splitFocusedPane(direction: .vertical)
        #expect(afterSplit.fired)
        let afterRemove = trackStructure(tree)
        _ = tree.removePane(id: b.id)
        #expect(afterRemove.fired)
    }

    @Test func splitReEqualizationNotifiesTheExistingSplitsRatioReader() throws {
        let (tree, id, a, b) = makeTwoPaneTree()
        tree.updateRatio(forSplitID: id, to: 0.7)
        let box = try #require(tree.root.ratioBox(forSplitID: id))
        let ratio = trackRatio(box)
        tree.focusedPaneID = a.id
        let c = tree.splitFocusedPane(direction: .horizontal)
        #expect(ratio.fired)
        #expect(tree.root.ratioBox(forSplitID: id) === box)
        for pane in [a.id, b.id, c.id] {
            let share = try #require(fraction(of: pane, in: tree.root))
            #expect(abs(share - 1.0 / 3.0) < 1e-9)
        }
    }
}
