// SplitTree.swift

import Foundation
import Observation
import OSLog

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "SplitTree")

// Used internally by rebalancingChain to signal whether paneID was found reachable
// through a contiguous same-direction chain from the current node.
private enum ChainSearchResult {
    case notFound
    // paneID is in this subtree, reachable through a D-direction chain from this node.
    case foundInDChain(SplitTreeNode)
    // paneID is in this subtree, but the path crossed a perpendicular split.
    case foundBelowBreak(SplitTreeNode)

    var updatedNode: SplitTreeNode? {
        switch self {
        case .notFound: return nil
        case .foundInDChain(let n): return n
        case .foundBelowBreak(let n): return n
        }
    }
}

public indirect enum SplitTreeNode {
    case leaf(PaneRuntime)
    case split(id: UUID, direction: SplitDirection, ratio: Double, left: SplitTreeNode, right: SplitTreeNode)
}

extension SplitTreeNode {
    public var firstLeafPaneID: UUID {
        switch self {
        case .leaf(let pane):
            return pane.id
        case .split(_, _, _, let left, _):
            return left.firstLeafPaneID
        }
    }

    public var firstLeafPane: PaneRuntime {
        switch self {
        case .leaf(let pane):
            return pane
        case .split(_, _, _, let left, _):
            return left.firstLeafPane
        }
    }

    public func findPane(id: UUID) -> PaneRuntime? {
        switch self {
        case .leaf(let pane):
            return pane.id == id ? pane : nil
        case .split(_, _, _, let left, let right):
            return left.findPane(id: id) ?? right.findPane(id: id)
        }
    }

    public var allLeafPanes: [PaneRuntime] {
        switch self {
        case .leaf(let pane):
            return [pane]
        case .split(_, _, _, let left, let right):
            return left.allLeafPanes + right.allLeafPanes
        }
    }

    /// All leaf panes in this subtree whose `isHidden` is `false`.
    public var visibleLeafPanes: [PaneRuntime] {
        switch self {
        case .leaf(let pane):
            return pane.isHidden ? [] : [pane]
        case .split(_, _, _, let left, let right):
            return left.visibleLeafPanes + right.visibleLeafPanes
        }
    }

    /// `true` when every leaf pane in this subtree is hidden.
    /// Used by `SplitNodeView` to collapse layout space for fully-hidden
    /// sub-trees and to suppress dividers adjacent to them.
    public var isEntirelyHidden: Bool {
        switch self {
        case .leaf(let pane):
            return pane.isHidden
        case .split(_, _, _, let left, let right):
            return left.isEntirelyHidden && right.isEntirelyHidden
        }
    }

    public func contains(paneID: UUID) -> Bool {
        findPane(id: paneID) != nil
    }
}

@Observable
public final class SplitTree {
    public var root: SplitTreeNode
    public var focusedPaneID: UUID

    /// The owning session, set once by `SessionRuntime.init` via
    /// ``attachToSession(_:)``. Every pane created afterward through
    /// ``splitFocusedPane(direction:ratio:inheritingFrom:)`` or
    /// ``splitFullDimension(direction:ratio:inheritingFrom:)`` is attached
    /// to it immediately (#0281's `BATTY_PANE_ID`/`BATTY_SESSION_ID`
    /// plumbing). `nil` for a standalone tree not owned by any session
    /// (e.g. a bare unit-test fixture).
    public internal(set) var sessionID: UUID?

    public init(root: SplitTreeNode) {
        self.root = root
        self.focusedPaneID = root.firstLeafPaneID
    }

    public convenience init() {
        self.init(root: .leaf(PaneRuntime()))
    }

    /// Attaches this tree and every pane it currently contains to
    /// `sessionID`. Called once by `SessionRuntime.init`.
    public func attachToSession(_ sessionID: UUID) {
        self.sessionID = sessionID
        for pane in allPanes {
            pane.attachToSession(sessionID)
        }
    }

    public var focusedPane: PaneRuntime {
        root.findPane(id: focusedPaneID) ?? root.firstLeafPane
    }

    public var allPanes: [PaneRuntime] {
        root.allLeafPanes
    }

    /// All panes in the tree whose `isHidden` is `false`.
    public var visiblePanes: [PaneRuntime] {
        root.visibleLeafPanes
    }

    /// Splits the focused pane, adding a new pane along `direction`.
    ///
    /// After insertion, every leaf in the contiguous same-direction chain that
    /// contains the new pane is re-equalized to an even 1/n fraction (#0255).
    /// Because of that, `ratio` no longer affects the final geometry of a
    /// same-axis split — it is retained for API compatibility but overridden by
    /// the equalization pass. A perpendicular split starts a fresh 50/50 axis.
    @discardableResult
    public func splitFocusedPane(
        direction: SplitDirection,
        ratio: Double = 0.5,
        inheritingFrom source: PaneRuntime? = nil
    ) -> PaneRuntime {
        let newPane = Self.makePane(inheritingFrom: source)
        if let sessionID {
            newPane.attachToSession(sessionID)
        }
        if let newRoot = SplitTreeNode.inserting(
            newPane: newPane,
            adjacentTo: focusedPaneID,
            direction: direction,
            ratio: ratio,
            into: root
        ) {
            // Rebalance the contiguous same-direction chain containing newPane so
            // all leaves in that chain have equal fractions (1/n).
            let result = SplitTreeNode.rebalancingChain(
                containing: newPane.id,
                direction: direction,
                in: newRoot,
                parentIsDSplit: false
            )
            root = result.updatedNode ?? newRoot
            focusedPaneID = newPane.id
        }
        return newPane
    }

    /// Wraps the whole tree in a new top-level split, adding a pane that
    /// spans the Session's full width (`.vertical` — new bottom row) or
    /// full height (`.horizontal` — new trailing column), instead of
    /// splitting only within the focused pane's bounds like
    /// `splitFocusedPane` does (#0262). The existing tree becomes the
    /// left/top child unchanged — no leaf pane is touched, so every
    /// existing Terminal Session survives the restructuring — and the new
    /// pane is the right/bottom child, matching `inserting(...)`'s
    /// convention of placing a new pane after the one it splits from.
    ///
    /// Unlike `splitFocusedPane`, this never chain-rebalances: it is a
    /// single wrap of whatever the tree currently is, so the new pane
    /// simply takes an even half (`ratio` default 0.5) of the outermost
    /// dimension regardless of how many panes already exist.
    @discardableResult
    public func splitFullDimension(
        direction: SplitDirection,
        ratio: Double = 0.5,
        inheritingFrom source: PaneRuntime? = nil
    ) -> PaneRuntime {
        let newPane = Self.makePane(inheritingFrom: source)
        if let sessionID {
            newPane.attachToSession(sessionID)
        }
        root = .split(id: UUID(), direction: direction, ratio: ratio, left: root, right: .leaf(newPane))
        focusedPaneID = newPane.id
        return newPane
    }

    private static func makePane(inheritingFrom source: PaneRuntime?) -> PaneRuntime {
        guard let sourceTab = source?.activeTab else {
            return PaneRuntime()
        }
        let cwd = sourceTab.terminal.workingDirectory
            ?? sourceTab.terminal.configuration.workingDirectory
        return PaneRuntime(tabs: [TabRuntime(workingDirectory: cwd)])
    }

    public func removeFocusedPane() {
        let leaves = root.allLeafPanes
        guard leaves.count > 1 else { return }
        guard let newRoot = SplitTreeNode.removingPane(focusedPaneID, from: root) else { return }
        root = newRoot
        focusedPaneID = newRoot.firstLeafPaneID
    }

    /// Removes a pane by id. Returns `true` when the tree became empty
    /// (the removed pane was the only one). Callers should treat that as
    /// "session is now empty and should be closed."
    @discardableResult
    public func removePane(id: UUID) -> Bool {
        guard let newRoot = SplitTreeNode.removingPane(id, from: root) else {
            return true
        }
        root = newRoot
        if !newRoot.contains(paneID: focusedPaneID) {
            focusedPaneID = newRoot.firstLeafPaneID
        }
        return false
    }

    public func updateRatio(forSplitID id: UUID, to newRatio: Double) {
        let clamped = max(0.05, min(0.95, newRatio))
        root = SplitTreeNode.updatingRatio(in: root, forID: id, to: clamped)
    }

    /// Swaps the positions of two leaf panes in the tree. The split structure
    /// and ratios are unchanged; only the leaf contents trade places.
    /// No-op if either id is not found.
    public func swapPanes(id idA: UUID, with idB: UUID) {
        guard idA != idB else {
            logger.notice("split-tree: swapPanes no-op reason=same-id id=\(idA, privacy: .public)")
            return
        }
        guard let paneA = root.findPane(id: idA) else {
            logger.notice("split-tree: swapPanes no-op missing=A id=\(idA, privacy: .public) other=\(idB, privacy: .public)")
            return
        }
        guard let paneB = root.findPane(id: idB) else {
            logger.notice("split-tree: swapPanes no-op missing=B id=\(idB, privacy: .public) other=\(idA, privacy: .public)")
            return
        }
        root = SplitTreeNode.swapping(paneA: paneA, paneB: paneB, in: root)
    }
}

extension SplitTreeNode {
    static func swapping(paneA: PaneRuntime, paneB: PaneRuntime, in node: SplitTreeNode) -> SplitTreeNode {
        switch node {
        case .leaf(let pane):
            if pane.id == paneA.id { return .leaf(paneB) }
            if pane.id == paneB.id { return .leaf(paneA) }
            return node
        case .split(let id, let dir, let ratio, let left, let right):
            return .split(
                id: id,
                direction: dir,
                ratio: ratio,
                left: swapping(paneA: paneA, paneB: paneB, in: left),
                right: swapping(paneA: paneA, paneB: paneB, in: right)
            )
        }
    }

    static func updatingRatio(in node: SplitTreeNode, forID id: UUID, to newRatio: Double) -> SplitTreeNode {
        switch node {
        case .leaf:
            return node
        case .split(let nodeID, let dir, let ratio, let left, let right):
            if nodeID == id {
                return .split(id: nodeID, direction: dir, ratio: newRatio, left: left, right: right)
            }
            return .split(
                id: nodeID,
                direction: dir,
                ratio: ratio,
                left: updatingRatio(in: left, forID: id, to: newRatio),
                right: updatingRatio(in: right, forID: id, to: newRatio)
            )
        }
    }

    static func removingPane(_ id: UUID, from node: SplitTreeNode) -> SplitTreeNode? {
        switch node {
        case .leaf(let pane):
            return pane.id == id ? nil : node
        case .split(let nodeID, let dir, let ratio, let left, let right):
            let newLeft = removingPane(id, from: left)
            let newRight = removingPane(id, from: right)
            switch (newLeft, newRight) {
            case (nil, nil):
                return nil
            case (nil, let r?):
                return r
            case (let l?, nil):
                return l
            case (let l?, let r?):
                return .split(id: nodeID, direction: dir, ratio: ratio, left: l, right: r)
            }
        }
    }

    static func inserting(
        newPane: PaneRuntime,
        adjacentTo paneID: UUID,
        direction: SplitDirection,
        ratio: Double,
        into node: SplitTreeNode
    ) -> SplitTreeNode? {
        switch node {
        case .leaf(let pane) where pane.id == paneID:
            return .split(
                id: UUID(),
                direction: direction,
                ratio: ratio,
                left: .leaf(pane),
                right: .leaf(newPane)
            )
        case .leaf:
            return nil
        case .split(let nodeID, let dir, let r, let left, let right):
            if let newLeft = inserting(
                newPane: newPane,
                adjacentTo: paneID,
                direction: direction,
                ratio: ratio,
                into: left
            ) {
                return .split(id: nodeID, direction: dir, ratio: r, left: newLeft, right: right)
            }
            if let newRight = inserting(
                newPane: newPane,
                adjacentTo: paneID,
                direction: direction,
                ratio: ratio,
                into: right
            ) {
                return .split(id: nodeID, direction: dir, ratio: r, left: left, right: newRight)
            }
            return nil
        }
    }

    // MARK: - Same-axis equalization

    /// Finds the maximal contiguous same-direction chain containing `paneID` and rebalances
    /// every ratio in that chain so all its leaf units get an equal fraction (1/n).
    /// A "chain leaf unit" is either an actual leaf pane or a perpendicular-direction subtree
    /// (which counts as one opaque unit). Perpendicular splits are never rebalanced here.
    ///
    /// `parentIsDSplit`: pass `true` when the calling split's direction equals `direction`.
    ///   The chain root is the highest D-split that has no D-split parent — identified by
    ///   `parentIsDSplit == false`. Rebalancing is applied only at the chain root.
    fileprivate static func rebalancingChain(
        containing paneID: UUID,
        direction: SplitDirection,
        in node: SplitTreeNode,
        parentIsDSplit: Bool
    ) -> ChainSearchResult {
        switch node {
        case .leaf(let pane):
            guard pane.id == paneID else { return .notFound }
            return .foundInDChain(node)

        case .split(let id, let dir, let ratio, let left, let right):
            if dir == direction {
                // We're in a D-split. Recurse with parentIsDSplit=true so children know they
                // are inside a D-chain and should not trigger chain-root rebalancing.
                let leftResult = rebalancingChain(containing: paneID, direction: direction, in: left, parentIsDSplit: true)
                let rightResult = rebalancingChain(containing: paneID, direction: direction, in: right, parentIsDSplit: true)

                switch (leftResult, rightResult) {
                case (.notFound, .notFound):
                    return .notFound

                case (.foundInDChain(let newLeft), _):
                    let updated = SplitTreeNode.split(id: id, direction: dir, ratio: ratio, left: newLeft, right: right)
                    if !parentIsDSplit {
                        // This is the chain root: apply equalization to the whole chain.
                        return .foundInDChain(rebalancedChain(updated, direction: direction))
                    }
                    return .foundInDChain(updated)

                case (_, .foundInDChain(let newRight)):
                    let updated = SplitTreeNode.split(id: id, direction: dir, ratio: ratio, left: left, right: newRight)
                    if !parentIsDSplit {
                        return .foundInDChain(rebalancedChain(updated, direction: direction))
                    }
                    return .foundInDChain(updated)

                // paneID was found but its path crossed a perpendicular split inside this D-subtree.
                // Propagate without rebalancing the outer D-chain.
                case (.foundBelowBreak(let newLeft), _):
                    return .foundBelowBreak(.split(id: id, direction: dir, ratio: ratio, left: newLeft, right: right))

                case (_, .foundBelowBreak(let newRight)):
                    return .foundBelowBreak(.split(id: id, direction: dir, ratio: ratio, left: left, right: newRight))
                }
            } else {
                // Non-D split breaks the chain. Recurse with parentIsDSplit=false so the next
                // D-split below will be treated as its own chain root.
                let leftResult = rebalancingChain(containing: paneID, direction: direction, in: left, parentIsDSplit: false)
                let rightResult = rebalancingChain(containing: paneID, direction: direction, in: right, parentIsDSplit: false)

                switch (leftResult, rightResult) {
                case (.notFound, .notFound):
                    return .notFound
                case (.foundInDChain(let newLeft), _):
                    return .foundBelowBreak(.split(id: id, direction: dir, ratio: ratio, left: newLeft, right: right))
                case (.foundBelowBreak(let newLeft), _):
                    return .foundBelowBreak(.split(id: id, direction: dir, ratio: ratio, left: newLeft, right: right))
                case (_, .foundInDChain(let newRight)):
                    return .foundBelowBreak(.split(id: id, direction: dir, ratio: ratio, left: left, right: newRight))
                case (_, .foundBelowBreak(let newRight)):
                    return .foundBelowBreak(.split(id: id, direction: dir, ratio: ratio, left: left, right: newRight))
                }
            }
        }
    }

    /// Sets the ratio of every D-direction split in this subtree so all visible
    /// chain leaves get equal fractions. Perpendicular splits are treated as
    /// single opaque units. Hidden leaves receive a ratio of 0 so they consume
    /// no rendered space and the stored ratio is restored when un-hidden by the
    /// next equalization pass on the next split.
    ///
    /// When all leaves in both arms are hidden (`total == 0`), the existing
    /// ratio is preserved unchanged — an all-hidden subtree is an edge case
    /// that cannot occur under the "≥1 visible pane" invariant, but the guard
    /// keeps ratio finite if the invariant is momentarily violated.
    fileprivate static func rebalancedChain(_ node: SplitTreeNode, direction: SplitDirection) -> SplitTreeNode {
        switch node {
        case .leaf:
            return node
        case .split(let id, let dir, _, let left, let right):
            guard dir == direction else { return node }
            let leftCount = countChainLeaves(left, direction: direction)
            let rightCount = countChainLeaves(right, direction: direction)
            let total = leftCount + rightCount
            guard total > 0 else {
                // All hidden — preserve the stored ratio unchanged.
                return node
            }
            return .split(
                id: id,
                direction: dir,
                ratio: Double(leftCount) / Double(total),
                left: rebalancedChain(left, direction: direction),
                right: rebalancedChain(right, direction: direction)
            )
        }
    }

    /// Counts the number of visible "chain leaf units" in a same-direction chain.
    /// Hidden leaves count as 0; visible leaves count as 1.
    /// Perpendicular-direction subtrees count as 0 if entirely hidden, 1 otherwise.
    /// This ensures equalization after a split distributes space only among
    /// visible panes — a hidden pane does not receive a fractional share (#0256).
    fileprivate static func countChainLeaves(_ node: SplitTreeNode, direction: SplitDirection) -> Int {
        switch node {
        case .leaf(let pane):
            return pane.isHidden ? 0 : 1
        case .split(_, let dir, _, let left, let right):
            guard dir == direction else {
                // Perpendicular subtree counts as one opaque unit if any pane is visible.
                return node.isEntirelyHidden ? 0 : 1
            }
            return countChainLeaves(left, direction: direction) + countChainLeaves(right, direction: direction)
        }
    }

    // MARK: - Pane positions (#0259)

    /// Column/row coordinates for every leaf pane in this subtree, derived
    /// purely from tree shape (no rendered geometry involved) so it works
    /// identically for the selected session, background sessions, hidden
    /// panes, and headless callers like the CLI (#0257).
    ///
    /// The tree is projected onto a virtual grid where every subtree
    /// occupies a rectangle: a `.horizontal` split places its children's
    /// rectangles side by side (the right child's columns start after the
    /// left child's full column span), a `.vertical` split stacks them
    /// (rows advance by the upper child's full row span), and a leaf is the
    /// top-left cell of its rectangle. Sibling rectangles are disjoint along
    /// the split axis, so every pane gets a unique coordinate for any tree
    /// shape. Span reservation is what makes mixed nesting safe: in
    /// `horizontal(vertical(horizontal(A,B), C), D)` the left subtree spans
    /// two columns, so D lands at 3/1 instead of colliding with B at 2/1 —
    /// the coordinates order panes the same way their rendered frame origins
    /// do, at the cost of an occasional gap in the numbering (there is no
    /// pane at 2/2 or 3/... other than D). Hidden panes are not
    /// special-cased: they occupy the same tree slot whether hidden or not,
    /// so they keep their coordinates (#0256).
    public func panePositions() -> [UUID: PanePosition] {
        var result: [UUID: PanePosition] = [:]
        assignPositions(into: &result, column: 1, row: 1)
        return result
    }

    /// The (columns, rows) extent of the virtual-grid rectangle this
    /// subtree occupies: a split sums its children's spans along the split
    /// axis and takes the max across it.
    private var gridSpan: (columns: Int, rows: Int) {
        switch self {
        case .leaf:
            return (1, 1)
        case .split(_, .horizontal, _, let left, let right):
            let l = left.gridSpan
            let r = right.gridSpan
            return (l.columns + r.columns, max(l.rows, r.rows))
        case .split(_, .vertical, _, let left, let right):
            let l = left.gridSpan
            let r = right.gridSpan
            return (max(l.columns, r.columns), l.rows + r.rows)
        }
    }

    private func assignPositions(
        into result: inout [UUID: PanePosition],
        column: Int,
        row: Int
    ) {
        switch self {
        case .leaf(let pane):
            result[pane.id] = PanePosition(column: column, row: row)
        case .split(_, .horizontal, _, let left, let right):
            left.assignPositions(into: &result, column: column, row: row)
            right.assignPositions(into: &result, column: column + left.gridSpan.columns, row: row)
        case .split(_, .vertical, _, let left, let right):
            left.assignPositions(into: &result, column: column, row: row)
            right.assignPositions(into: &result, column: column, row: row + left.gridSpan.rows)
        }
    }
}

/// A pane's column/row coordinates within its session's split layout, as
/// shown in the sidebar pane row (#0259): `1/1` is the first pane, `2/1` is
/// a horizontal sibling (second column, first row), `1/3` is the third pane
/// in a vertical chain (first column, third row).
public struct PanePosition: Hashable, Sendable {
    public let column: Int
    public let row: Int

    public init(column: Int, row: Int) {
        self.column = column
        self.row = row
    }

    public var label: String { "\(column)/\(row)" }
}

extension SplitTree {
    /// Column/row coordinates for every pane currently in the tree, keyed by
    /// pane id. See `SplitTreeNode.panePositions()` for the derivation rule.
    public var panePositions: [UUID: PanePosition] {
        root.panePositions()
    }

    /// All panes ordered column-major — every pane in column 1 top-to-bottom,
    /// then column 2, and so on — for the sidebar pane list (#0263). Each
    /// column's vertically-stacked panes stay grouped together before the
    /// next column starts. `allPanes` is tree-traversal order (depth-first),
    /// which is not column-major in general (e.g.
    /// `horizontal(vertical(A, C), B)` lists A, C, B in traversal order,
    /// which happens to already be column-major there, but
    /// `horizontal(vertical(A, C), horizontal(B, D))`-style layouts diverge).
    /// This is derived fresh from `panePositions` each time rather than
    /// stored, so it self-maintains through splits, closes, and
    /// rearrangements without any ordering state to keep in sync.
    public var panesSortedByColumnThenRow: [PaneRuntime] {
        let positions = panePositions
        return allPanes.sorted { lhs, rhs in
            let lhsPosition = positions[lhs.id] ?? PanePosition(column: 0, row: 0)
            let rhsPosition = positions[rhs.id] ?? PanePosition(column: 0, row: 0)
            if lhsPosition.column != rhsPosition.column {
                return lhsPosition.column < rhsPosition.column
            }
            return lhsPosition.row < rhsPosition.row
        }
    }
}
