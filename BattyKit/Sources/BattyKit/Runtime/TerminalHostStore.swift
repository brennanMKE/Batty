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
///   * Own the persistent ``TerminalHostView``. The host is handed to
///     SwiftUI via ``TerminalHostInstaller`` (an `NSViewRepresentable`
///     that returns this same instance from every `makeNSView` call —
///     Pattern 3 from `nsviewrepresentable-state-persistence.md`).
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

    /// The single persistent host. Created on init and held strongly here
    /// for the store's lifetime. ``TerminalHostInstaller.makeNSView``
    /// returns this instance directly so SwiftUI never constructs a new
    /// one — even when the representable is torn down and rebuilt, the
    /// host and all its terminal subviews survive in this store.
    let hostView: TerminalHostView

    /// `tab.id` → live terminal view. Each entry is created once and
    /// persists until `releaseTerminalView(forTabID:)` is called. A tab's
    /// `TabRuntime.terminalNSView` strong-references the view; the host
    /// also strong-references it as a subview. Both go away on close.
    private var terminalViews: [UUID: AppTerminalView] = [:]

    /// `tab.id` → live ``TabRuntime``, held weakly so a tab disappearing
    /// from the model layer (without a paired `releaseTerminalView`) does
    /// not keep the runtime alive. Used by drag-and-drop routing in
    /// ``TerminalHostView`` to map a hit-tested terminal subview back to
    /// the runtime so we can send the dropped paths through its surface.
    private var tabRuntimes: [UUID: WeakTabRuntime] = [:]

    /// `tab.id` → most recent placement (host-local frame + visibility
    /// flag). Stored so re-applying the latest placement on a re-mount
    /// is a single dictionary read.
    private var placements: [UUID: Placement] = [:]

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
        view.delegate = tab.terminalDelegate
        view.controller = tab.terminal.controller
        view.configuration = tab.terminal.configuration
        view.isHidden = true
        view.autoresizingMask = []
        view.translatesAutoresizingMaskIntoConstraints = true
        hostView.addSubview(view)
        terminalViews[tab.id] = view
        tabRuntimes[tab.id] = WeakTabRuntime(tab)
        tab.terminalNSView = view
        logger.debug("created terminal view for tab \(tab.id, privacy: .public); host has \(self.terminalViews.count, privacy: .public) view(s)")
        return view
    }

    /// Look up the `tab.id` whose `AppTerminalView` is `view`. Returns
    /// `nil` if the view isn't currently registered (e.g. the tab was
    /// closed in the same runloop turn). Used by ``TerminalHostView`` to
    /// resolve which terminal a drop landed on.
    public func tabID(for view: AppTerminalView) -> UUID? {
        for (id, registered) in terminalViews where registered === view {
            return id
        }
        return nil
    }

    /// The `TabRuntime` whose terminal is tracked under `id`, or `nil` if
    /// the runtime has been deallocated. Held weakly inside the store —
    /// callers should not assume the returned reference will outlive the
    /// current main-actor turn.
    public func tabRuntime(forTabID id: UUID) -> TabRuntime? {
        tabRuntimes[id]?.runtime
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
        tabRuntimes.removeValue(forKey: id)
        view.removeFromSuperview()
        logger.debug("released terminal view for tab \(id, privacy: .public); host has \(self.terminalViews.count, privacy: .public) view(s) remaining")
    }

    /// Reconcile every known terminal view against the supplied
    /// placement map. Tabs with a placement become visible at the given
    /// frame; tabs without a placement (or with `isVisible == false`) are
    /// hidden but kept attached. This is the bulk mutator the SwiftUI
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

    /// Single-tab placement update that merges into the existing map
    /// instead of replacing it. The placeholder calls this from its
    /// `.onGeometryChange` backstop when its frame in the host's named
    /// coordinate space settles — a path that catches geometry changes
    /// the `PreferenceKey` flow misses on cold launch (#0101), where the
    /// first preference emission carries a stale frame and the second
    /// pass doesn't re-emit because the placeholder's locally proposed
    /// size didn't change.
    public func setPlacement(_ placement: Placement, forTabID id: UUID) {
        placements[id] = placement
        guard let view = terminalViews[id] else { return }
        if placement.isVisible {
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

    /// Host-local placement for a single terminal view. `frame` is in
    /// the host's own coordinate space (top-left origin because the
    /// host is `isFlipped == true`, matching SwiftUI). `isVisible == false`
    /// keeps the view attached but hidden.
    public struct Placement: Equatable, Sendable {
        public var frame: NSRect
        public var isVisible: Bool

        public init(frame: NSRect, isVisible: Bool) {
            self.frame = frame
            self.isVisible = isVisible
        }
    }

    private struct WeakTabRuntime {
        weak var runtime: TabRuntime?
        init(_ runtime: TabRuntime) { self.runtime = runtime }
    }
}
