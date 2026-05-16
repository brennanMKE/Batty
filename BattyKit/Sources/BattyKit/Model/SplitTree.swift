// SplitTree.swift

import Foundation
import Observation

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

    public func contains(paneID: UUID) -> Bool {
        findPane(id: paneID) != nil
    }
}

@Observable
public final class SplitTree {
    public var root: SplitTreeNode
    public var focusedPaneID: UUID

    public init(root: SplitTreeNode) {
        self.root = root
        self.focusedPaneID = root.firstLeafPaneID
    }

    public convenience init() {
        self.init(root: .leaf(PaneRuntime()))
    }

    public var focusedPane: PaneRuntime {
        root.findPane(id: focusedPaneID) ?? root.firstLeafPane
    }

    public var allPanes: [PaneRuntime] {
        root.allLeafPanes
    }

    @discardableResult
    public func splitFocusedPane(
        direction: SplitDirection,
        ratio: Double = 0.5,
        inheritingFrom source: PaneRuntime? = nil
    ) -> PaneRuntime {
        let newPane: PaneRuntime
        if let sourceTab = source?.activeTab {
            let cwd = sourceTab.terminal.workingDirectory
                ?? sourceTab.terminal.configuration.workingDirectory
            newPane = PaneRuntime(tabs: [TabRuntime(workingDirectory: cwd)])
        } else {
            newPane = PaneRuntime()
        }
        if let newRoot = SplitTreeNode.inserting(
            newPane: newPane,
            adjacentTo: focusedPaneID,
            direction: direction,
            ratio: ratio,
            into: root
        ) {
            root = newRoot
            focusedPaneID = newPane.id
        }
        return newPane
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

    /// Exchanges the two leaf panes identified by `a` and `b` so they trade
    /// positions in the tree. The split structure (directions, ratios,
    /// node ids) is preserved — only the `PaneRuntime` references at the
    /// two leaves are swapped. Because `PaneRuntime` is a reference type
    /// carrying its tabs and all per-pane runtime state, focus tracking
    /// (which is by pane id) follows the pane automatically.
    ///
    /// No-op if either id is missing or `a == b`.
    @discardableResult
    public func swapPanes(_ a: UUID, _ b: UUID) -> Bool {
        guard a != b else { return false }
        guard let paneA = root.findPane(id: a), let paneB = root.findPane(id: b) else {
            return false
        }
        root = SplitTreeNode.swappingLeaves(in: root, a: paneA, b: paneB)
        return true
    }
}

extension SplitTreeNode {
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

    static func swappingLeaves(in node: SplitTreeNode, a: PaneRuntime, b: PaneRuntime) -> SplitTreeNode {
        switch node {
        case .leaf(let pane):
            if pane.id == a.id {
                return .leaf(b)
            } else if pane.id == b.id {
                return .leaf(a)
            }
            return node
        case .split(let id, let dir, let ratio, let left, let right):
            return .split(
                id: id,
                direction: dir,
                ratio: ratio,
                left: swappingLeaves(in: left, a: a, b: b),
                right: swappingLeaves(in: right, a: a, b: b)
            )
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
}
