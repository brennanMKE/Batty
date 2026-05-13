// TerminalHostView.swift

import AppKit
import GhosttyTerminal
import OSLog
import UniformTypeIdentifiers

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

    /// Tab whose terminal subview a Finder drag currently hovers over.
    /// Tracked so `draggingExited` knows which tab to clear, even if the
    /// pointer left the host without crossing a different subview.
    private var dragHoverTabID: UUID?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        layer?.backgroundColor = NSColor.clear.cgColor
        autoresizingMask = [.width, .height]
        // Drop-target registration MUST live on the AppKit host, not on
        // a SwiftUI sibling. AppKit dispatches drags to the deepest view
        // at the cursor that has registered for the type — it does not
        // fall through an AppKit subview to a SwiftUI drop target below.
        // See #0102 for the dispatch-path mismatch this fixes.
        registerForDraggedTypes([.fileURL])
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

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard hasFileURL(in: sender) else { return [] }
        updateHoverTab(for: sender)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard hasFileURL(in: sender) else { return [] }
        updateHoverTab(for: sender)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        clearHoverTab()
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        hasFileURL(in: sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { clearHoverTab() }
        let pasteboard = sender.draggingPasteboard
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard
            let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL],
            !urls.isEmpty
        else {
            return false
        }
        let pointInHost = convert(sender.draggingLocation, from: nil)
        guard let tab = terminalTab(at: pointInHost) else {
            logger.debug("drop ignored: no terminal under point \(String(describing: pointInHost), privacy: .public)")
            return false
        }
        let paths = urls.compactMap { $0.isFileURL ? $0.path : nil }
        guard !paths.isEmpty else { return false }
        tab.terminal.send(ShellQuote.joinPaths(paths))
        return true
    }

    private func hasFileURL(in sender: NSDraggingInfo) -> Bool {
        let pasteboard = sender.draggingPasteboard
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        return pasteboard.canReadObject(forClasses: [NSURL.self], options: options)
    }

    private func updateHoverTab(for sender: NSDraggingInfo) {
        let pointInHost = convert(sender.draggingLocation, from: nil)
        let tab = terminalTab(at: pointInHost)
        let nextID = tab?.id
        if nextID == dragHoverTabID { return }
        if let previousID = dragHoverTabID,
           let previous = TerminalHostStore.shared.tabRuntime(forTabID: previousID) {
            previous.isDragHovering = false
        }
        dragHoverTabID = nextID
        tab?.isDragHovering = true
    }

    private func clearHoverTab() {
        guard let id = dragHoverTabID else { return }
        dragHoverTabID = nil
        if let tab = TerminalHostStore.shared.tabRuntime(forTabID: id) {
            tab.isDragHovering = false
        }
    }

    private func terminalTab(at pointInHost: NSPoint) -> TabRuntime? {
        for subview in subviews.reversed() {
            guard let terminal = subview as? AppTerminalView,
                  !terminal.isHidden,
                  terminal.frame.contains(pointInHost),
                  let id = TerminalHostStore.shared.tabID(for: terminal)
            else { continue }
            return TerminalHostStore.shared.tabRuntime(forTabID: id)
        }
        return nil
    }
}
