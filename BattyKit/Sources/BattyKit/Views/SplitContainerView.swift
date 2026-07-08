// SplitContainerView.swift

import SwiftUI

private struct EnvironmentPaneAllottedSizeKey: EnvironmentKey {
    static let defaultValue: CGSize? = nil
}

extension EnvironmentValues {
    /// The exact width/height `SplitLayout.placeSubviews` allotted to this
    /// branch of the split tree. Set by `DraggableSplitView` from a
    /// `GeometryReader`-measured size (never from a child's own reported
    /// frame), and read by `PaneView` to clamp its own frame before
    /// `.overlay` and `.clipped()` run.
    ///
    /// Why this exists (#0261): `SlidingTabBar`'s tab-chip row uses
    /// `.fixedSize()` internally so chips don't get squashed illegibly.
    /// When a pane is too narrow to fit its chips at their minimum width,
    /// the chip row — and therefore `PaneView`'s outer `VStack` — reports
    /// an ideal size *wider* than what `SplitLayout` proposed, because
    /// SwiftUI containers propagate a refusing child's ideal size upward
    /// rather than clamping to the proposal. `SplitLayout`'s divider and
    /// the next pane are still placed at the originally-computed position,
    /// unaware of the overflow, so the two disagree. `PaneView`'s focus
    /// highlight (and the bell-flash / drag-hover / swap-target overlays
    /// that share its shape) are plain `.overlay`s, which track whatever
    /// frame `PaneView` actually renders at — so they inherited the
    /// oversized frame and drew past the true divider position. Reading
    /// the allotted size here and applying it as a hard `.frame(width:
    /// height:)` before `.clipped()`/`.overlay()` forces `PaneView` back
    /// to the size `SplitLayout` actually gave it; any tab-chip content
    /// that still doesn't fit is clipped instead of bleeding into the
    /// neighboring pane.
    var paneAllottedSize: CGSize? {
        get { self[EnvironmentPaneAllottedSizeKey.self] }
        set { self[EnvironmentPaneAllottedSizeKey.self] = newValue }
    }
}

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
            // Hidden leaf: zero-size placeholder. The surface stays alive in
            // TerminalHostStore because no placement is reported and the
            // AppTerminalView stays in the host with isHidden = true (#0256).
            if pane.isHidden {
                return AnyView(Color.clear.frame(width: 0, height: 0))
            }
            return AnyView(PaneView(pane: pane, tree: tree))

        case let .split(id, direction, ratio, left, right):
            // If one arm is entirely hidden, give the visible arm 100% with
            // no divider. The stored `ratio` is preserved so it's restored
            // when the pane is un-hidden (the next split re-equalizes only
            // visible panes, so the ratio reflects the visible share).
            if left.isEntirelyHidden {
                return AnyView(SplitNodeView(tree: tree, node: right))
            }
            if right.isEntirelyHidden {
                return AnyView(SplitNodeView(tree: tree, node: left))
            }
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

    /// The size `SplitLayout.placeSubviews` will allot to a child, given
    /// this container's own current size. Computed synchronously from a
    /// `GeometryReader` (not from a child's self-reported frame) so it
    /// can't be corrupted by a child that refuses to shrink — see
    /// ``EnvironmentValues/paneAllottedSize`` for why this exists (#0261).
    private func allottedSize(containerSize: CGSize, main: CGFloat) -> CGSize? {
        let crossLength = direction == .horizontal ? containerSize.height : containerSize.width
        guard main > 0, crossLength > 0 else { return nil }
        return direction == .horizontal
            ? CGSize(width: main, height: crossLength)
            : CGSize(width: crossLength, height: main)
    }

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
        GeometryReader { proxy in
            let totalLength = direction == .horizontal ? proxy.size.width : proxy.size.height
            let usable = max(0, totalLength - Self.dividerThickness)
            let leftLength = max(0, usable * ratio)
            let rightLength = max(0, usable - leftLength)

            SplitLayout(direction: direction, ratio: ratio, dividerThickness: Self.dividerThickness) {
                leftContent()
                    .environment(\.paneAllottedSize, allottedSize(containerSize: proxy.size, main: leftLength))
                divider
                rightContent()
                    .environment(\.paneAllottedSize, allottedSize(containerSize: proxy.size, main: rightLength))
            }
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
