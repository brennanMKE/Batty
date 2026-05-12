// TerminalHostStore.swift

import AppKit
import Foundation
import GhosttyTerminal
import OSLog

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "TerminalHostStore")

/// Long-lived owner of the per-window `TerminalHostView` and every
/// `AppTerminalView` that has been created for a still-living tab.
///
/// Lifetime: created lazily on first access via ``shared`` and lives for
/// the duration of the process. Because Batty is single-window-by-default,
/// a single shared store is enough; if multi-window lands later, this
/// becomes one store per window keyed by the window identifier.
///
/// Responsibilities:
///   * Vend the persistent ``TerminalHostView`` and ensure it is installed
///     as a subview of the active window's `contentView` exactly once.
///   * Lazily create one `AppTerminalView` per `TabRuntime.id` on first
///     request and add it to the host as `isHidden = true`.
///   * Expose a single mutator (`updatePlacements(_:)`) that the
///     SwiftUI-side coordinator calls when geometry, visibility, or
///     selection changes. The host repositions and toggles `isHidden`
///     accordingly — it never removes a terminal until the tab is
///     explicitly closed via ``releaseTerminalView(forTabID:)``.
@MainActor
public final class TerminalHostStore {

    public static let shared = TerminalHostStore()

    /// The single persistent host. Created on demand, added to the
    /// window's contentView the first time ``attachHost(to:)`` is called
    /// with that window, and never removed.
    let hostView: TerminalHostView

    /// `tab.id` → live terminal view. Each entry is created once and
    /// persists until `releaseTerminalView(forTabID:)` is called. A tab's
    /// `TabRuntime.terminalNSView` strong-references the view; the host
    /// also strong-references it as a subview. Both go away on close.
    private var terminalViews: [UUID: AppTerminalView] = [:]

    /// `tab.id` → most recent placement (window-coordinate frame +
    /// visibility flag). Stored so re-applying the latest placement on
    /// (re-)attach is a single dictionary read.
    private var placements: [UUID: Placement] = [:]

    /// Window the host is currently parented to. Once set it does not
    /// change for the host's lifetime.
    private weak var attachedWindow: NSWindow?

    public init() {
        self.hostView = TerminalHostView(frame: .zero)
    }

    /// Vend the long-lived `AppTerminalView` for a tab, creating one on
    /// first request. The view is added to the host with `isHidden = true`
    /// so it's part of the window's view hierarchy from the moment it
    /// exists — libghostty's surface (PTY + scrollback) starts up the
    /// first time it sees a non-nil `window`, and `viewDidMoveToWindow`
    /// never fires again for the life of the view.
    @discardableResult
    public func terminalView(for tab: TabRuntime) -> AppTerminalView {
        if let existing = terminalViews[tab.id] {
            return existing
        }
        let view = AppTerminalView(frame: .zero)
        view.delegate = tab.terminal
        view.controller = tab.terminal.controller
        view.configuration = tab.terminal.configuration
        view.isHidden = true
        view.autoresizingMask = []
        view.translatesAutoresizingMaskIntoConstraints = true
        hostView.addSubview(view)
        terminalViews[tab.id] = view
        tab.terminalNSView = view
        logger.debug("created terminal view for tab \(tab.id, privacy: .public); host has \(self.terminalViews.count, privacy: .public) view(s)")
        return view
    }

    /// True iff a terminal view has already been created for this tab.
    /// Used by tests; production code goes through `terminalView(for:)`.
    func hasTerminalView(forTabID id: UUID) -> Bool {
        terminalViews[id] != nil
    }

    /// Remove and release the terminal view for `tabID`. Called only when
    /// the tab is being closed for real (see `AppStateStore.closeTab(id:)`).
    /// libghostty's `viewDidMoveToWindow(nil)` plus the coordinator's
    /// `deinit` together free the surface and shut down the PTY.
    public func releaseTerminalView(forTabID id: UUID) {
        guard let view = terminalViews.removeValue(forKey: id) else { return }
        placements.removeValue(forKey: id)
        view.removeFromSuperview()
        logger.debug("released terminal view for tab \(id, privacy: .public); host has \(self.terminalViews.count, privacy: .public) view(s) remaining")
    }

    /// Reconcile every known terminal view against the supplied
    /// placement map. Tabs with a placement become visible at the given
    /// frame; tabs without a placement (or with `isVisible == false`) are
    /// hidden but kept attached. This is the only mutator the SwiftUI
    /// coordinator calls during navigation.
    public func updatePlacements(_ newPlacements: [UUID: Placement]) {
        placements = newPlacements
        for (id, view) in terminalViews {
            if let placement = newPlacements[id], placement.isVisible {
                if view.frame != placement.frame {
                    view.frame = placement.frame
                }
                if view.isHidden {
                    view.isHidden = false
                }
            } else if !view.isHidden {
                view.isHidden = true
            }
        }
    }

    /// Install the host into the window's contentView if not already
    /// attached. Idempotent — calling this a second time with the same
    /// window is a no-op; calling it with a different window logs and
    /// keeps the original (Batty is single-window-by-default).
    public func attachHost(to window: NSWindow) {
        if let attached = attachedWindow, attached === window {
            return
        }
        if attachedWindow != nil {
            logger.error("attachHost called with a second window; ignoring (single-window app)")
            return
        }
        guard let contentView = window.contentView else {
            logger.error("attachHost: window.contentView is nil; cannot install host")
            return
        }
        attachedWindow = window
        hostView.frame = contentView.bounds
        hostView.autoresizingMask = [.width, .height]
        contentView.addSubview(hostView, positioned: .above, relativeTo: nil)
        let contentName = String(describing: type(of: contentView))
        let contentFlipped = contentView.isFlipped
        logger.debug("attached host to window: contentView=\(contentName, privacy: .public) flipped=\(contentFlipped, privacy: .public)")
    }

    /// Window-coordinate placement for a single terminal view.
    /// `frame` is expressed in the host's coordinate space (which is the
    /// window's contentView coordinate space since the host fills it);
    /// `isVisible == false` keeps the view attached but hidden.
    public struct Placement: Equatable, Sendable {
        public var frame: NSRect
        public var isVisible: Bool

        public init(frame: NSRect, isVisible: Bool) {
            self.frame = frame
            self.isVisible = isVisible
        }
    }
}
