// SplitTreeFullDimensionTests.swift

import Foundation
import Testing
@testable import BattyKit

/// `SplitTree.splitFullDimension` (#0262) — the Option-modified split that
/// wraps the whole tree in a new top-level split, instead of splitting only
/// within the focused pane's bounds like `splitFocusedPane` does.
@MainActor
struct SplitTreeFullDimensionTests {

    @Test func horizontalWrapAddsATrailingFullHeightColumn() {
        let tree = SplitTree()
        let existing = tree.focusedPane

        let newPane = tree.splitFullDimension(direction: .horizontal)

        guard case .split(_, let direction, let ratio, let left, let right) = tree.root else {
            Issue.record("expected root to become a .split after the wrap")
            return
        }
        #expect(direction == .horizontal)
        #expect(ratio == 0.5)
        #expect(left.firstLeafPaneID == existing.id)
        #expect(right.firstLeafPaneID == newPane.id)
        #expect(tree.allPanes.count == 2)
        #expect(tree.focusedPaneID == newPane.id)
    }

    @Test func verticalWrapAddsATrailingFullWidthRow() {
        let tree = SplitTree()
        let existing = tree.focusedPane

        let newPane = tree.splitFullDimension(direction: .vertical)

        guard case .split(_, let direction, _, let left, let right) = tree.root else {
            Issue.record("expected root to become a .split after the wrap")
            return
        }
        #expect(direction == .vertical)
        #expect(left.firstLeafPaneID == existing.id)
        #expect(right.firstLeafPaneID == newPane.id)
        #expect(tree.allPanes.count == 2)
    }

    @Test func wrapPreservesEveryExistingPane() {
        // Build a small multi-pane tree first, then wrap it — every pane
        // that existed before the wrap must survive with its identity
        // (and therefore its Terminal Session) intact (docs/view-hierarchy.md).
        let tree = SplitTree()
        let paneA = tree.focusedPane
        tree.splitFocusedPane(direction: .horizontal)
        let paneB = tree.allPanes.first { $0.id != paneA.id }!

        tree.focusedPaneID = paneA.id
        tree.splitFocusedPane(direction: .vertical)
        let paneC = tree.allPanes.first { ![paneA.id, paneB.id].contains($0.id) }!

        let newPane = tree.splitFullDimension(direction: .vertical)

        let ids = Set(tree.allPanes.map(\.id))
        #expect(ids == Set([paneA.id, paneB.id, paneC.id, newPane.id]))
    }

    @Test func wrapInheritsFocusedPaneCWD() {
        let tree = SplitTree()
        let source = tree.focusedPane
        source.activeTab?.terminal.configuration.workingDirectory = "/Users/test/Developer/Batty"

        let newPane = tree.splitFullDimension(direction: .horizontal, inheritingFrom: source)

        #expect(
            newPane.tabs[0].terminal.configuration.workingDirectory
                == "/Users/test/Developer/Batty"
        )
    }

    @Test func wrapWithoutSourceHasNoCWD() {
        let tree = SplitTree()
        tree.focusedPane.activeTab?.terminal.configuration.workingDirectory = "/Users/test/Developer/Batty"

        let newPane = tree.splitFullDimension(direction: .vertical)

        #expect(newPane.tabs[0].terminal.configuration.workingDirectory == nil)
    }
}
