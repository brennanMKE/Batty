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
    @Bindable var tree: SplitTree
    let node: SplitTreeNode

    var body: AnyView {
        switch node {
        case .leaf(let pane):
            return AnyView(PaneView(pane: pane, tree: tree))
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

    @Environment(\.themeChrome) private var themeChrome
    @State private var dragStartRatio: Double?
    @State private var containerLength: CGFloat = 0

    private static var dividerThickness: CGFloat { 4 }

    /// A single visible themed divider painted uniformly along its full
    /// length — this is the pre-#0135 design (intentionally-visible
    /// macOS-style split separator), with the system separator color
    /// swapped for a themed one when a theme is active. Rounds 3-7 of
    /// #0135 tried to make this divider invisible by splitting it into
    /// chrome and body regions, but the SwiftUI↔libghostty rendering
    /// boundary meant the divider could never truly blend. Going back
    /// to a visible divider eliminates the seam by making it intentional.
    private var dividerColor: Color {
        themeChrome?.divider ?? Color(nsColor: .separatorColor)
    }

    var body: some View {
        SplitLayout(direction: direction, ratio: ratio, dividerThickness: Self.dividerThickness) {
            leftContent()
            divider
            rightContent()
        }
        .onGeometryChange(for: CGFloat.self, of: {
            direction == .horizontal ? $0.size.width : $0.size.height
        }) {
            containerLength = $0
        }
    }

    @ViewBuilder
    private var divider: some View {
        Rectangle()
            .fill(dividerColor)
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
                        guard containerLength > 0 else { return }
                        let startRatio = dragStartRatio ?? ratio
                        if dragStartRatio == nil { dragStartRatio = startRatio }
                        let delta = direction == .horizontal ? value.translation.width : value.translation.height
                        let newRatio = startRatio + (delta / containerLength)
                        onRatioChange(newRatio)
                    }
                    .onEnded { _ in
                        dragStartRatio = nil
                    }
            )
    }
}

private struct SplitLayout: Layout {
    let direction: SplitDirection
    let ratio: Double
    let dividerThickness: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 3 else { return }
        let totalLength = direction == .horizontal ? bounds.width : bounds.height
        let crossLength = direction == .horizontal ? bounds.height : bounds.width
        let usable = max(0, totalLength - dividerThickness)
        let leftLength = max(0, usable * ratio)
        let rightLength = max(0, usable - leftLength)

        switch direction {
        case .horizontal:
            subviews[0].place(
                at: CGPoint(x: bounds.minX, y: bounds.minY),
                proposal: ProposedViewSize(width: leftLength, height: crossLength)
            )
            subviews[1].place(
                at: CGPoint(x: bounds.minX + leftLength, y: bounds.minY),
                proposal: ProposedViewSize(width: dividerThickness, height: crossLength)
            )
            subviews[2].place(
                at: CGPoint(x: bounds.minX + leftLength + dividerThickness, y: bounds.minY),
                proposal: ProposedViewSize(width: rightLength, height: crossLength)
            )
        case .vertical:
            subviews[0].place(
                at: CGPoint(x: bounds.minX, y: bounds.minY),
                proposal: ProposedViewSize(width: crossLength, height: leftLength)
            )
            subviews[1].place(
                at: CGPoint(x: bounds.minX, y: bounds.minY + leftLength),
                proposal: ProposedViewSize(width: crossLength, height: dividerThickness)
            )
            subviews[2].place(
                at: CGPoint(x: bounds.minX, y: bounds.minY + leftLength + dividerThickness),
                proposal: ProposedViewSize(width: crossLength, height: rightLength)
            )
        }
    }
}
