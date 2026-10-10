// WindowCornerOutline.swift

import SwiftUI

/// Which corners of a rectangle coincide with a rounded corner of the
/// window. Pure value type: computed from the split tree, never measured
/// from layout, so it can't feed observed state back into the view update
/// that reads it (docs/swiftui-observation-rules.md).
struct WindowCorners: OptionSet, Sendable, Hashable {
    let rawValue: Int

    static let topLeading = WindowCorners(rawValue: 1 << 0)
    static let topTrailing = WindowCorners(rawValue: 1 << 1)
    static let bottomLeading = WindowCorners(rawValue: 1 << 2)
    static let bottomTrailing = WindowCorners(rawValue: 1 << 3)

    static let all: WindowCorners = [.topLeading, .topTrailing, .bottomLeading, .bottomTrailing]

    /// Window corners the Session detail area occupies. The top edge sits
    /// under the title bar, so only the bottom corners are ever rounded
    /// against content; the bottom-leading one belongs to the Sidebar column
    /// unless the Sidebar is hidden.
    static func detailArea(sidebarHidden: Bool) -> WindowCorners {
        sidebarHidden ? [.bottomLeading, .bottomTrailing] : [.bottomTrailing]
    }

    /// Corners the first (leading/top) child of a split inherits from its
    /// parent's corners.
    func firstChild(of direction: SplitDirection) -> WindowCorners {
        switch direction {
        case .horizontal: intersection([.topLeading, .bottomLeading])
        case .vertical: intersection([.topLeading, .topTrailing])
        }
    }

    /// Corners the second (trailing/bottom) child of a split inherits.
    func secondChild(of direction: SplitDirection) -> WindowCorners {
        switch direction {
        case .horizontal: intersection([.topTrailing, .bottomTrailing])
        case .vertical: intersection([.bottomLeading, .bottomTrailing])
        }
    }

    /// Per-corner radii for a Pane outline: `windowRadius` at corners that
    /// coincide with a window corner, `interiorRadius` elsewhere.
    func radii(windowRadius: CGFloat, interiorRadius: CGFloat) -> RectangleCornerRadii {
        RectangleCornerRadii(
            topLeading: contains(.topLeading) ? windowRadius : interiorRadius,
            bottomLeading: contains(.bottomLeading) ? windowRadius : interiorRadius,
            bottomTrailing: contains(.bottomTrailing) ? windowRadius : interiorRadius,
            topTrailing: contains(.topTrailing) ? windowRadius : interiorRadius
        )
    }
}

private struct WindowCornersKey: EnvironmentKey {
    static let defaultValue: WindowCorners = []
}

extension EnvironmentValues {
    /// The window corners the enclosing split-tree node's frame touches.
    var paneWindowCorners: WindowCorners {
        get { self[WindowCornersKey.self] }
        set { self[WindowCornersKey.self] = newValue }
    }
}

/// Window corner radius used where the system doesn't resolve one for us
/// (macOS before 26). Windows since macOS 11 round their corners at 10 pt,
/// title bar or toolbar alike. AppKit exposes no API for the radius
/// (`NSWindow` has no corner property), so this is a named constant, the
/// fallback #0339 allows. On macOS 26+ the radius comes from the system
/// through `ConcentricRectangle` instead.
enum WindowCornerMetrics {
    static let legacyWindowRadius: CGFloat = 10
    static let interiorRadius: CGFloat = 4
}

/// The accent stroke shared by the Pane focus, bell-flash, file-drop and
/// swap-target outlines. Follows the window's rounded corner at the Pane
/// corners that coincide with one; interior corners keep the small radius.
/// Always `allowsHitTesting(false)` so it never intercepts terminal input.
/// On macOS 26+ the `paneWindowCorners` environment is unused because
/// `ConcentricRectangle` resolves the corners itself; `WindowCorners` only
/// drives the pre-26 fallback.
struct PaneAccentStroke: View {
    @Environment(\.paneWindowCorners) private var windowCorners
    let color: Color
    let lineWidth: CGFloat

    var body: some View {
        stroke
            .allowsHitTesting(false)
    }

    @ViewBuilder
    private var stroke: some View {
        if #available(macOS 26.0, *) {
            let shape = ConcentricRectangle(
                corners: .concentric(minimum: .fixed(WindowCornerMetrics.interiorRadius)),
                isUniform: false
            )
            shape
                .stroke(color, lineWidth: lineWidth * 2)
                .clipShape(shape)
        } else {
            UnevenRoundedRectangle(
                cornerRadii: windowCorners.radii(
                    windowRadius: WindowCornerMetrics.legacyWindowRadius,
                    interiorRadius: WindowCornerMetrics.interiorRadius
                ),
                style: .continuous
            )
            .strokeBorder(color, lineWidth: lineWidth)
        }
    }
}
