// TerminalHostView.swift

import AppKit
import GhosttyTerminal
import OSLog

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "TerminalHostView")

/// Single persistent AppKit container that holds every active
/// `AppTerminalView` as a subview for the lifetime of its tab.
///
/// The host lives outside the SwiftUI rebuild path entirely — it is added
/// once as a subview of the window's `contentView` and is never removed,
/// re-added, or re-parented during navigation. SwiftUI only renders
/// transparent placeholder views that report their on-screen geometry
/// (via a preference key); the host reads those frames and positions the
/// corresponding terminal view to overlay the placeholder. Tabs that are
/// not the active tab in the focused pane of the selected session are
/// kept in the host but `isHidden`.
///
/// This means a terminal view's `viewDidMoveToWindow` runs exactly twice
/// in its lifetime: once when it is first added to the host (on first
/// appearance), and once when its tab is closed and the view is released.
/// Navigation, splits, pane focus changes, sidebar selection, and window
/// resizes never reparent the terminal — they only mutate `frame` and
/// `isHidden`.
@MainActor
final class TerminalHostView: NSView {

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        layer?.backgroundColor = NSColor.clear.cgColor
        autoresizingMask = [.width, .height]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// The host itself is decorative — it never paints. Click-throughs
    /// land on the terminal subview underneath when one is positioned
    /// at the click point. Iterate visible subviews top-down (last-added
    /// is topmost) and delegate to `subview.hitTest(point)`. Each
    /// subview's hitTest handles its own coord conversion and bounds
    /// check; we just pick the topmost non-nil result. Returning nil
    /// when no terminal sits at the point lets the click fall through
    /// to whatever SwiftUI sibling is above us in the window's view
    /// chain.
    ///
    /// Note: do NOT add a redundant `subview.bounds.contains(local)`
    /// pre-check here. The host has `isFlipped == true` while
    /// `AppTerminalView` keeps the default `false`, so manually
    /// converting the point can disagree with NSView's internal
    /// converted-point logic on cases like a vertical split's bottom
    /// pane (see #0090).
    override func hitTest(_ point: NSPoint) -> NSView? {
        for subview in subviews.reversed() where !subview.isHidden {
            if let target = subview.hitTest(point) {
                return target
            }
        }
        return nil
    }
}
