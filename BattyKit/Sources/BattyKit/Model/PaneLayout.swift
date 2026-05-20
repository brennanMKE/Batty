// PaneLayout.swift

import CoreGraphics
import Foundation

/// A fixed catalog of pane arrangements that can be applied to a single-pane session.
/// Each case knows how to describe itself visually (via `layoutPanes`) and how to
/// build the corresponding split tree (via `apply(to:)`).
public enum PaneLayout: String, CaseIterable, Identifiable {
    case singlePane
    case horizontalSplit
    case verticalSplit
    case threeColumns
    case threeRows
    case mainLeftTwoRight
    case mainRightTwoLeft
    case mainTopTwoBottom
    case mainBottomTwoTop
    case twoByTwoGrid

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .singlePane:        return "Single pane"
        case .horizontalSplit:   return "Horizontal split"
        case .verticalSplit:     return "Vertical split"
        case .threeColumns:      return "Three columns"
        case .threeRows:         return "Three rows"
        case .mainLeftTwoRight:  return "Main left, two right"
        case .mainRightTwoLeft:  return "Main right, two left"
        case .mainTopTwoBottom:  return "Main top, two bottom"
        case .mainBottomTwoTop:  return "Main bottom, two top"
        case .twoByTwoGrid:      return "2\u{00D7}2 grid"
        }
    }

    public var paneCount: Int {
        switch self {
        case .singlePane:                          return 1
        case .horizontalSplit, .verticalSplit:     return 2
        case .threeColumns, .threeRows:            return 3
        case .mainLeftTwoRight, .mainRightTwoLeft: return 3
        case .mainTopTwoBottom, .mainBottomTwoTop: return 3
        case .twoByTwoGrid:                        return 4
        }
    }

    // MARK: - Visual representation

    public struct LayoutPane {
        public let frame: CGRect
        public let isPrimary: Bool
    }

    public var layoutPanes: [LayoutPane] {
        switch self {
        case .singlePane:
            return [LayoutPane(frame: CGRect(x: 0, y: 0, width: 1, height: 1), isPrimary: true)]

        case .horizontalSplit:
            return [
                LayoutPane(frame: CGRect(x: 0,   y: 0, width: 0.5, height: 1), isPrimary: true),
                LayoutPane(frame: CGRect(x: 0.5, y: 0, width: 0.5, height: 1), isPrimary: false),
            ]

        case .verticalSplit:
            return [
                LayoutPane(frame: CGRect(x: 0, y: 0,   width: 1, height: 0.5), isPrimary: true),
                LayoutPane(frame: CGRect(x: 0, y: 0.5, width: 1, height: 0.5), isPrimary: false),
            ]

        case .threeColumns:
            let w = 1.0 / 3.0
            return [
                LayoutPane(frame: CGRect(x: 0,     y: 0, width: w, height: 1), isPrimary: true),
                LayoutPane(frame: CGRect(x: w,     y: 0, width: w, height: 1), isPrimary: false),
                LayoutPane(frame: CGRect(x: w * 2, y: 0, width: w, height: 1), isPrimary: false),
            ]

        case .threeRows:
            let h = 1.0 / 3.0
            return [
                LayoutPane(frame: CGRect(x: 0, y: 0,     width: 1, height: h), isPrimary: true),
                LayoutPane(frame: CGRect(x: 0, y: h,     width: 1, height: h), isPrimary: false),
                LayoutPane(frame: CGRect(x: 0, y: h * 2, width: 1, height: h), isPrimary: false),
            ]

        case .mainLeftTwoRight:
            return [
                LayoutPane(frame: CGRect(x: 0,   y: 0,   width: 0.5, height: 1),   isPrimary: true),
                LayoutPane(frame: CGRect(x: 0.5, y: 0,   width: 0.5, height: 0.5), isPrimary: false),
                LayoutPane(frame: CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5), isPrimary: false),
            ]

        case .mainRightTwoLeft:
            return [
                LayoutPane(frame: CGRect(x: 0,   y: 0,   width: 0.5, height: 0.5), isPrimary: false),
                LayoutPane(frame: CGRect(x: 0,   y: 0.5, width: 0.5, height: 0.5), isPrimary: false),
                LayoutPane(frame: CGRect(x: 0.5, y: 0,   width: 0.5, height: 1),   isPrimary: true),
            ]

        case .mainTopTwoBottom:
            return [
                LayoutPane(frame: CGRect(x: 0,   y: 0,   width: 1,   height: 0.5), isPrimary: true),
                LayoutPane(frame: CGRect(x: 0,   y: 0.5, width: 0.5, height: 0.5), isPrimary: false),
                LayoutPane(frame: CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5), isPrimary: false),
            ]

        case .mainBottomTwoTop:
            return [
                LayoutPane(frame: CGRect(x: 0,   y: 0,   width: 0.5, height: 0.5), isPrimary: false),
                LayoutPane(frame: CGRect(x: 0.5, y: 0,   width: 0.5, height: 0.5), isPrimary: false),
                LayoutPane(frame: CGRect(x: 0,   y: 0.5, width: 1,   height: 0.5), isPrimary: true),
            ]

        case .twoByTwoGrid:
            return [
                LayoutPane(frame: CGRect(x: 0,   y: 0,   width: 0.5, height: 0.5), isPrimary: true),
                LayoutPane(frame: CGRect(x: 0.5, y: 0,   width: 0.5, height: 0.5), isPrimary: false),
                LayoutPane(frame: CGRect(x: 0,   y: 0.5, width: 0.5, height: 0.5), isPrimary: false),
                LayoutPane(frame: CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5), isPrimary: false),
            ]
        }
    }

    // MARK: - Tree application

    /// Rebuilds `tree` to match this layout. Silently does nothing when the
    /// tree already has more than one pane — the picker is only for fresh
    /// single-pane sessions.
    public func apply(to tree: SplitTree) {
        guard tree.allPanes.count == 1 else { return }
        let primary = tree.focusedPane

        switch self {
        case .singlePane:
            break

        case .horizontalSplit:
            tree.splitFocusedPane(direction: .horizontal, inheritingFrom: primary)

        case .verticalSplit:
            tree.splitFocusedPane(direction: .vertical, inheritingFrom: primary)

        case .threeColumns:
            // primary | B | C
            // Focused = primary. Split horizontally at 1/3 → pane B takes the right 2/3.
            // Then set focused to B and split horizontally at 0.5 → B | C.
            tree.focusedPaneID = primary.id
            let paneB = tree.splitFocusedPane(direction: .horizontal, ratio: 1.0 / 3.0, inheritingFrom: primary)
            tree.focusedPaneID = paneB.id
            tree.splitFocusedPane(direction: .horizontal, ratio: 0.5, inheritingFrom: primary)

        case .threeRows:
            // primary / B / C
            tree.focusedPaneID = primary.id
            let paneB = tree.splitFocusedPane(direction: .vertical, ratio: 1.0 / 3.0, inheritingFrom: primary)
            tree.focusedPaneID = paneB.id
            tree.splitFocusedPane(direction: .vertical, ratio: 0.5, inheritingFrom: primary)

        case .mainLeftTwoRight:
            // primary | (B / C)
            // Split primary horizontally → B (right half). Then split B vertically → C.
            tree.focusedPaneID = primary.id
            let paneB = tree.splitFocusedPane(direction: .horizontal, inheritingFrom: primary)
            tree.focusedPaneID = paneB.id
            tree.splitFocusedPane(direction: .vertical, inheritingFrom: primary)

        case .mainRightTwoLeft:
            // (primary / C) | B
            // Split primary horizontally → B (right). Then split primary vertically → C.
            tree.focusedPaneID = primary.id
            tree.splitFocusedPane(direction: .horizontal, inheritingFrom: primary)
            tree.focusedPaneID = primary.id
            tree.splitFocusedPane(direction: .vertical, inheritingFrom: primary)

        case .mainTopTwoBottom:
            // primary / (B | C)
            // Split primary vertically → B (bottom half). Then split B horizontally → C.
            tree.focusedPaneID = primary.id
            let paneB = tree.splitFocusedPane(direction: .vertical, inheritingFrom: primary)
            tree.focusedPaneID = paneB.id
            tree.splitFocusedPane(direction: .horizontal, inheritingFrom: primary)

        case .mainBottomTwoTop:
            // (primary | C) / B
            // Split primary vertically → B (bottom). Then split primary horizontally → C.
            // B is the wide bottom pane; primary and C are the two top panes.
            tree.focusedPaneID = primary.id
            let paneB = tree.splitFocusedPane(direction: .vertical, inheritingFrom: primary)
            tree.focusedPaneID = primary.id
            tree.splitFocusedPane(direction: .horizontal, inheritingFrom: primary)
            tree.focusedPaneID = paneB.id

        case .twoByTwoGrid:
            // (primary | B) / (C | D)
            // Split primary horizontally → pane B. Split primary vertically → pane C.
            // Set focused to B, split vertically → pane D.
            tree.focusedPaneID = primary.id
            let paneB = tree.splitFocusedPane(direction: .horizontal, inheritingFrom: primary)
            tree.focusedPaneID = primary.id
            tree.splitFocusedPane(direction: .vertical, inheritingFrom: primary)
            tree.focusedPaneID = paneB.id
            tree.splitFocusedPane(direction: .vertical, inheritingFrom: primary)
        }

        tree.focusedPaneID = primary.id
    }
}
