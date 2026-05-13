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
    /// at the click point; clicks that miss every terminal fall through
    /// to whatever SwiftUI sibling is above us in the window's view
    /// chain.
    ///
    /// Delegating to `super.hitTest` is intentional — it handles the
    /// coordinate-space conversion from `point` (which arrives in the
    /// host's superview's coords) into the host's own coords (the host
    /// is `isFlipped`; the SwiftUI parent typically isn't), then descends
    /// into subviews using each subview's `frame` stored in host coords.
    ///
    /// The prior implementation iterated `subviews.reversed()` and called
    /// `subview.hitTest(point)` directly without converting the
    /// coordinate space, which produced a perfectly-symmetric top↔bottom
    /// inversion on vertical splits (#0090): a click at the visual
    /// bottom of the host arrived with `y` measured from the SwiftUI
    /// parent's top, but `subview.hitTest` interpreted it against
    /// subview frames stored in the host's flipped space, so the click
    /// at visual y=590 was tested against subviews at host-local y=590
    /// (= the bottom subview's frame), but the input y had been measured
    /// from the OTHER end, etc. The default impl gets this right.
    ///
    /// The only customization vs default: when no subview matches but
    /// the point IS inside our bounds, the default returns `self`,
    /// blocking fall-through to SwiftUI siblings. Return `nil` instead.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let result = super.hitTest(point)
        return result === self ? nil : result
    }
}
