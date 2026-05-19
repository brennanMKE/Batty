// SplitContainerView.swift

import SwiftUI

public struct SplitContainerView: View {
    @Bindable public var tree: SplitTree

    public init(tree: SplitTree) {
        self.tree = tree
    }

    @Environment(\.themeChrome) private var themeChrome

    public var body: some View {
        // Resolve the divider colors at the SplitContainerView level (where
        // `@Environment(\.themeChrome)` reliably resolves) and pass them
        // down explicitly. Prior rounds tried to read the env at
        // `DraggableSplitView` and via a `PreferenceKey` from `PaneView`,
        // both of which travel through the `AnyView` wrappers in
        // `SplitNodeView` and were not reliably propagating. Explicit
        // parameters bypass that whole class of bug. #0135 round 5.
        let chromeColor = themeChrome?.chromeBackground
        let bodyColor = themeChrome?.windowBackground
        SplitNodeView(
            tree: tree,
            node: tree.root,
            dividerChromeColor: chromeColor,
            dividerBodyColor: bodyColor
        )
    }
}

/// Height of a pane's chrome strip (the tab bar + drag handle row).
/// Matches `SlidingTabBar`'s `barHeight` default of 36pt — the only
/// vertically-sized element in `PaneView`'s chrome `HStack`. Held as a
/// constant rather than measured via a `PreferenceKey` because round 3's
/// preference-based plumbing didn't propagate through the `AnyView`
/// wrappers in `SplitNodeView` (#0135 round 4), leaving the divider's
/// chrome region at 0 height and painting the body color full-height.
/// If `SlidingTabBar.barHeight` changes upstream, this must be updated
/// in lockstep.
private let chromeStripHeight: CGFloat = 36

private struct SplitNodeView: View {
    @Bindable var tree: SplitTree
    let node: SplitTreeNode
    let dividerChromeColor: Color?
    let dividerBodyColor: Color?

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
                    dividerChromeColor: dividerChromeColor,
                    dividerBodyColor: dividerBodyColor,
                    leftContent: {
                        SplitNodeView(
                            tree: tree,
                            node: left,
                            dividerChromeColor: dividerChromeColor,
                            dividerBodyColor: dividerBodyColor
                        )
                    },
                    rightContent: {
                        SplitNodeView(
                            tree: tree,
                            node: right,
                            dividerChromeColor: dividerChromeColor,
                            dividerBodyColor: dividerBodyColor
                        )
                    }
                )
            )
        }
    }
}

private struct DraggableSplitView<Left: View, Right: View>: View {
    let direction: SplitDirection
    let ratio: Double
    let onRatioChange: (Double) -> Void
    let dividerChromeColor: Color?
    let dividerBodyColor: Color?
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
    }

    /// Chrome region of the divider — sits in the tab-bar strip. When
    /// themed, matches the surrounding panes' chrome background so the
    /// 4pt gap is invisible. When unthemed, falls back to the system
    /// separator so the divider remains weakly visible on the default
    /// macOS chrome (the pre-#0135 look).
    private var resolvedChromeColor: Color {
        dividerChromeColor ?? Color(nsColor: .separatorColor)
    }

    /// Body region of the divider — sits in the terminal canvas area.
    /// When themed, matches the window background (which is the terminal
    /// canvas color), so the 4pt gap is invisible against the terminal.
    /// When unthemed, falls back to the system separator.
    private var resolvedBodyColor: Color {
        dividerBodyColor ?? Color(nsColor: .separatorColor)
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
                .fill(resolvedChromeColor)
                .frame(width: Self.dividerThickness, height: chromeHeight)
            Rectangle()
                .fill(resolvedBodyColor)
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
            .fill(resolvedBodyColor)
            .frame(width: containerSize.width, height: Self.dividerThickness)
    }
}
