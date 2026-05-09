// SplitContainerView.swift

import SwiftUI

public struct SplitContainerView: View {
    @Bindable public var tree: SplitTree

    public init(tree: SplitTree) {
        self.tree = tree
    }

    public var body: some View {
        SplitNodeView(node: tree.root)
    }
}

private struct SplitNodeView: View {
    let node: SplitTreeNode

    var body: AnyView {
        switch node {
        case .leaf(let pane):
            return AnyView(PaneView(pane: pane))
        case .split(.horizontal, _, let left, let right):
            return AnyView(
                HSplitView {
                    SplitNodeView(node: left)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    SplitNodeView(node: right)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            )
        case .split(.vertical, _, let left, let right):
            return AnyView(
                VSplitView {
                    SplitNodeView(node: left)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    SplitNodeView(node: right)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            )
        }
    }
}
