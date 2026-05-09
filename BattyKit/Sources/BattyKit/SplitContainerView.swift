// SplitContainerView.swift

import SwiftUI

public struct SplitContainerView: View {
    @Bindable public var tree: SplitTree

    public init(tree: SplitTree) {
        self.tree = tree
    }

    public var body: some View {
        SplitNodeView(tree: tree, node: tree.root)
    }
}

private struct SplitNodeView: View {
    let tree: SplitTree
    let node: SplitTreeNode

    var body: AnyView {
        switch node {
        case .leaf(let pane):
            return AnyView(PaneView(pane: pane))
        case let .split(id, direction, ratio, left, right):
            return AnyView(
                DraggableSplitView(
                    direction: direction,
                    ratio: ratio,
                    onRatioChange: { newRatio in
                        tree.updateRatio(forSplitID: id, to: newRatio)
                    },
                    leftContent: { SplitNodeView(tree: tree, node: left) },
                    rightContent: { SplitNodeView(tree: tree, node: right) }
                )
            )
        }
    }
}

private struct DraggableSplitView<Left: View, Right: View>: View {
    let direction: SplitDirection
    let ratio: Double
    let onRatioChange: (Double) -> Void
    @ViewBuilder let leftContent: () -> Left
    @ViewBuilder let rightContent: () -> Right

    @State private var dragStartRatio: Double?

    private static var dividerThickness: CGFloat { 4 }

    var body: some View {
        GeometryReader { geo in
            let totalLength = direction == .horizontal ? geo.size.width : geo.size.height
            let usable = max(0, totalLength - Self.dividerThickness)
            let leftLength = max(0, usable * ratio)
            let rightLength = max(0, usable - leftLength)

            switch direction {
            case .horizontal:
                HStack(spacing: 0) {
                    leftContent()
                        .frame(width: leftLength, height: geo.size.height)
                    divider(totalLength: totalLength)
                    rightContent()
                        .frame(width: rightLength, height: geo.size.height)
                }
            case .vertical:
                VStack(spacing: 0) {
                    leftContent()
                        .frame(width: geo.size.width, height: leftLength)
                    divider(totalLength: totalLength)
                    rightContent()
                        .frame(width: geo.size.width, height: rightLength)
                }
            }
        }
    }

    @ViewBuilder
    private func divider(totalLength: CGFloat) -> some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(
                width: direction == .horizontal ? Self.dividerThickness : nil,
                height: direction == .vertical ? Self.dividerThickness : nil
            )
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering {
                    if direction == .horizontal {
                        NSCursor.resizeLeftRight.push()
                    } else {
                        NSCursor.resizeUpDown.push()
                    }
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        guard totalLength > 0 else { return }
                        let startRatio = dragStartRatio ?? ratio
                        if dragStartRatio == nil { dragStartRatio = startRatio }
                        let delta = direction == .horizontal ? value.translation.width : value.translation.height
                        let newRatio = startRatio + (delta / totalLength)
                        onRatioChange(newRatio)
                    }
                    .onEnded { _ in
                        dragStartRatio = nil
                    }
            )
    }
}
