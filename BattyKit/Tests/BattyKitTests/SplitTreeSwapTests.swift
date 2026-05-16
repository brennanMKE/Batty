// SplitTreeSwapTests.swift

import Foundation
import Testing
@testable import BattyKit

@MainActor
struct SplitTreeSwapTests {

    @Test func swapTwoLeavesInHorizontalSplitExchangesPositions() {
        let left = PaneRuntime()
        let right = PaneRuntime()
        let tree = SplitTree(root: .split(
            id: UUID(),
            direction: .horizontal,
            ratio: 0.5,
            left: .leaf(left),
            right: .leaf(right)
        ))

        let didSwap = tree.swapPanes(left.id, right.id)

        #expect(didSwap)
        guard case let .split(_, direction, ratio, newLeft, newRight) = tree.root else {
            Issue.record("expected split root")
            return
        }
        #expect(direction == .horizontal)
        #expect(ratio == 0.5)
        if case .leaf(let pane) = newLeft {
            #expect(pane.id == right.id)
        } else {
            Issue.record("left should be a leaf")
        }
        if case .leaf(let pane) = newRight {
            #expect(pane.id == left.id)
        } else {
            Issue.record("right should be a leaf")
        }
    }

    @Test func swapPreservesNestedSplitStructure() {
        let topLeft = PaneRuntime()
        let topRight = PaneRuntime()
        let bottom = PaneRuntime()
        let topSplitID = UUID()
        let rootSplitID = UUID()
        let tree = SplitTree(root: .split(
            id: rootSplitID,
            direction: .vertical,
            ratio: 0.7,
            left: .split(
                id: topSplitID,
                direction: .horizontal,
                ratio: 0.3,
                left: .leaf(topLeft),
                right: .leaf(topRight)
            ),
            right: .leaf(bottom)
        ))

        #expect(tree.swapPanes(topLeft.id, bottom.id))

        guard case let .split(rootID, rootDir, rootRatio, newLeft, newRight) = tree.root else {
            Issue.record("expected split root")
            return
        }
        #expect(rootID == rootSplitID)
        #expect(rootDir == .vertical)
        #expect(rootRatio == 0.7)
        if case .leaf(let pane) = newRight {
            #expect(pane.id == topLeft.id)
        } else {
            Issue.record("right leaf should be the swapped pane")
        }
        guard case let .split(innerID, innerDir, innerRatio, innerLeft, innerRight) = newLeft else {
            Issue.record("expected inner split preserved")
            return
        }
        #expect(innerID == topSplitID)
        #expect(innerDir == .horizontal)
        #expect(innerRatio == 0.3)
        if case .leaf(let pane) = innerLeft {
            #expect(pane.id == bottom.id)
        } else {
            Issue.record("inner left should hold the swapped pane")
        }
        if case .leaf(let pane) = innerRight {
            #expect(pane.id == topRight.id)
        } else {
            Issue.record("inner right should be unchanged")
        }
    }

    @Test func swapWithUnknownIDIsNoOp() {
        let left = PaneRuntime()
        let right = PaneRuntime()
        let tree = SplitTree(root: .split(
            id: UUID(),
            direction: .horizontal,
            ratio: 0.5,
            left: .leaf(left),
            right: .leaf(right)
        ))

        let didSwap = tree.swapPanes(left.id, UUID())

        #expect(!didSwap)
        if case let .split(_, _, _, l, r) = tree.root {
            if case .leaf(let pane) = l { #expect(pane.id == left.id) }
            if case .leaf(let pane) = r { #expect(pane.id == right.id) }
        } else {
            Issue.record("expected split root")
        }
    }

    @Test func swapSelfIsNoOp() {
        let left = PaneRuntime()
        let right = PaneRuntime()
        let tree = SplitTree(root: .split(
            id: UUID(),
            direction: .horizontal,
            ratio: 0.5,
            left: .leaf(left),
            right: .leaf(right)
        ))

        let didSwap = tree.swapPanes(left.id, left.id)

        #expect(!didSwap)
    }

    @Test func swapPreservesPaneIdentityAndTabs() {
        let leftTab = TabRuntime()
        let rightTab = TabRuntime()
        let left = PaneRuntime(tabs: [leftTab])
        let right = PaneRuntime(tabs: [rightTab])
        let tree = SplitTree(root: .split(
            id: UUID(),
            direction: .horizontal,
            ratio: 0.5,
            left: .leaf(left),
            right: .leaf(right)
        ))

        #expect(tree.swapPanes(left.id, right.id))

        // The pane runtime references travel with their tabs — same id,
        // same tabs, just at the other tree position.
        let leftPane = tree.root.findPane(id: left.id)
        #expect(leftPane?.tabs.contains(where: { $0.id == leftTab.id }) == true)
        let rightPane = tree.root.findPane(id: right.id)
        #expect(rightPane?.tabs.contains(where: { $0.id == rightTab.id }) == true)
    }

    @Test func swapKeepsFocusedPaneIDPointingAtSamePane() {
        let left = PaneRuntime()
        let right = PaneRuntime()
        let tree = SplitTree(root: .split(
            id: UUID(),
            direction: .horizontal,
            ratio: 0.5,
            left: .leaf(left),
            right: .leaf(right)
        ))
        tree.focusedPaneID = left.id

        #expect(tree.swapPanes(left.id, right.id))

        // Focus is by pane id, so the originally-dragged pane stays
        // focused at its new tree position.
        #expect(tree.focusedPaneID == left.id)
        #expect(tree.focusedPane.id == left.id)
    }
}
