// SplitTree.swift

import Foundation
import Observation

public indirect enum SplitTreeNode {
    case leaf(PaneRuntime)
    case split(direction: SplitDirection, ratio: Double, left: SplitTreeNode, right: SplitTreeNode)
}

extension SplitTreeNode {
    public var firstLeafPaneID: UUID {
        switch self {
        case .leaf(let pane):
            return pane.id
        case .split(_, _, let left, _):
            return left.firstLeafPaneID
        }
    }

    public var firstLeafPane: PaneRuntime {
        switch self {
        case .leaf(let pane):
            return pane
        case .split(_, _, let left, _):
            return left.firstLeafPane
        }
    }

    public func findPane(id: UUID) -> PaneRuntime? {
        switch self {
        case .leaf(let pane):
            return pane.id == id ? pane : nil
        case .split(_, _, let left, let right):
            return left.findPane(id: id) ?? right.findPane(id: id)
        }
    }

    public var allLeafPanes: [PaneRuntime] {
        switch self {
        case .leaf(let pane):
            return [pane]
        case .split(_, _, let left, let right):
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
        ratio: Double = 0.5
    ) -> PaneRuntime {
        let newPane = PaneRuntime()
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
}

extension SplitTreeNode {
    static func removingPane(_ id: UUID, from node: SplitTreeNode) -> SplitTreeNode? {
        switch node {
        case .leaf(let pane):
            return pane.id == id ? nil : node
        case .split(let dir, let ratio, let left, let right):
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
                return .split(direction: dir, ratio: ratio, left: l, right: r)
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
                direction: direction,
                ratio: ratio,
                left: .leaf(pane),
                right: .leaf(newPane)
            )
        case .leaf:
            return nil
        case .split(let dir, let r, let left, let right):
            if let newLeft = inserting(
                newPane: newPane,
                adjacentTo: paneID,
                direction: direction,
                ratio: ratio,
                into: left
            ) {
                return .split(direction: dir, ratio: r, left: newLeft, right: right)
            }
            if let newRight = inserting(
                newPane: newPane,
                adjacentTo: paneID,
                direction: direction,
                ratio: ratio,
                into: right
            ) {
                return .split(direction: dir, ratio: r, left: left, right: newRight)
            }
            return nil
        }
    }
}
