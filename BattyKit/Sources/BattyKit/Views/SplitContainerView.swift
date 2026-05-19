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

/// Bubbles the per-pane chrome strip height up to enclosing
/// `DraggableSplitView`s so the divider can paint its chrome region
/// with the chrome background, keeping the chrome band visually
/// continuous across split panes (#0135 round 3).
struct ChromeStripHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
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
    @State private var chromeStripHeight: CGFloat = 0

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
                    divider(totalLength: totalLength, containerSize: geo.size)
                    rightContent()
                        .frame(width: rightLength, height: geo.size.height)
                }
            case .vertical:
                VStack(spacing: 0) {
                    leftContent()
                        .frame(width: geo.size.width, height: leftLength)
                    divider(totalLength: totalLength, containerSize: geo.size)
                    rightContent()
                        .frame(width: geo.size.width, height: rightLength)
                }
            }
        }
        .onPreferenceChange(ChromeStripHeightPreferenceKey.self) { newValue in
            chromeStripHeight = newValue
        }
    }

    private var dividerBodyColor: Color {
        themeChrome?.divider ?? Color(nsColor: .separatorColor)
    }

    /// Color used to "hide" the divider inside the chrome strip region so
    /// adjacent panes' chrome bands appear seamless. When no theme is
    /// active, the chrome strip is `Color.clear` so we fall back to the
    /// divider color (matches the pre-#0135-round-3 behavior).
    private var dividerChromeColor: Color {
        themeChrome?.chromeBackground ?? dividerBodyColor
    }

    @ViewBuilder
    private func divider(totalLength: CGFloat, containerSize: CGSize) -> some View {
        Group {
            switch direction {
            case .horizontal:
                horizontalDivider(containerSize: containerSize)
            case .vertical:
                verticalDivider(containerSize: containerSize)
            }
        }
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

    @ViewBuilder
    private func horizontalDivider(containerSize: CGSize) -> some View {
        let chromeHeight = min(max(chromeStripHeight, 0), containerSize.height)
        let bodyHeight = max(0, containerSize.height - chromeHeight)
        VStack(spacing: 0) {
            Rectangle()
                .fill(dividerChromeColor)
                .frame(width: Self.dividerThickness, height: chromeHeight)
            Rectangle()
                .fill(dividerBodyColor)
                .frame(width: Self.dividerThickness, height: bodyHeight)
        }
        .frame(width: Self.dividerThickness, height: containerSize.height)
    }

    @ViewBuilder
    private func verticalDivider(containerSize: CGSize) -> some View {
        // Vertical splits stack panes top/bottom; each pane's chrome
        // strip sits at its own top edge, so a horizontal divider
        // never intersects a chrome strip and the body color paints
        // the whole rule.
        Rectangle()
            .fill(dividerBodyColor)
            .frame(width: containerSize.width, height: Self.dividerThickness)
    }
}
