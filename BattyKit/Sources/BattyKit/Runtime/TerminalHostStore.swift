// TerminalHostStore.swift

import AppKit
import Foundation
import GhosttyTerminal
import OSLog

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "TerminalHostStore")

/// Process-wide registry of per-window `TerminalHostView`s and every
/// `AppTerminalView` created for a still-living tab.
///
/// Lifetime: created lazily on first access via ``shared`` and lives for
/// the duration of the process.
///
/// One `TerminalHostView` is created per content window and held
/// permanently until that window closes and all of its tabs have been
/// released via ``releaseTerminalView(forTabID:)``. The single-window
/// case is therefore identical to the previous singleton-`hostView`
/// design; the map just happens to have one entry.
///
/// Responsibilities:
///   * Lazily create and permanently own one ``TerminalHostView`` per
///     ``WindowID`` via ``hostView(forWindowID:)``. The host is returned
///     directly by ``TerminalHostInstaller`` (Pattern 3 from
///     `nsviewrepresentable-state-persistence.md`).
///   * Lazily create one `AppTerminalView` per `TabRuntime.id` on first
///     request and add it to the owning window's host with `isHidden = true`.
///   * Track which window each tab's view was installed into
///     (`tabWindowMap`) so placement updates flow per window and one
///     window's preference emissions cannot affect another window's terminals.
///   * Expose per-window placement mutators (``updatePlacements(_:forWindowID:)``
///     and ``setPlacement(_:forTabID:)``) that are scoped to the window that
///     owns each tab.
///   * Release a host only after every one of its tabs has gone through
///     ``releaseTerminalView(forTabID:)`` (teardown gating).
@MainActor
public final class TerminalHostStore {

    public static let shared = TerminalHostStore()

    /// `WindowID` → persistent host view for that window. Entries are
    /// created lazily in ``hostView(forWindowID:)`` and removed in
    /// ``releaseHost(forWindowID:)`` once all tabs have been released.
    private var hosts: [WindowID: TerminalHostView] = [:]

    /// `tab.id` → live terminal view. Each entry is created once and
    /// persists until `releaseTerminalView(forTabID:)` is called. A tab's
    /// `TabRuntime.terminalNSView` strong-references the view; the host
    /// also strong-references it as a subview. Both go away on close.
    private var terminalViews: [UUID: AppTerminalView] = [:]

    /// `tab.id` → the `WindowID` of the window whose host the view lives
    /// in. Established when the view is created and never changes — an
    /// `AppTerminalView` is never reparented across hosts (`view-hierarchy.md`
    /// §4 cross-window clause).
    private var tabWindowMap: [UUID: WindowID] = [:]

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

    public init() {}

    // MARK: - Per-window host access

    /// Returns the persistent ``TerminalHostView`` for `windowID`, creating
    /// it on first call. The returned instance is the same object for the
    /// window's entire lifetime — ``TerminalHostInstaller`` calls this from
    /// `makeNSView` and returns it directly (Pattern 3).
    func hostView(forWindowID windowID: WindowID) -> TerminalHostView {
        if let existing = hosts[windowID] {
            return existing
        }
        let host = TerminalHostView(frame: .zero)
        host.windowID = windowID
        hosts[windowID] = host
        logger.debug("created host for window \(windowID.value, privacy: .public); total hosts=\(self.hosts.count, privacy: .public)")
        return host
    }

    /// Release the host for `windowID` if and only if no terminal views
    /// belonging to that window remain registered. Called by the window-close
    /// path **after** every tab in the window has gone through
    /// ``releaseTerminalView(forTabID:)``.
    ///
    /// If tabs are still present (teardown gating: the precondition was not
    /// met) the host is left in place and a warning is logged.
    func releaseHost(forWindowID windowID: WindowID) {
        let orphans = tabWindowMap.filter { $0.value == windowID }
        guard orphans.isEmpty else {
            logger.warning("releaseHost window=\(windowID.value, privacy: .public): \(orphans.count, privacy: .public) tab(s) still registered; host kept")
            return
        }
        guard hosts[windowID] != nil else { return }
        hosts.removeValue(forKey: windowID)
        logger.debug("released host for window \(windowID.value, privacy: .public); total hosts=\(self.hosts.count, privacy: .public)")
    }

    // MARK: - Terminal view lifecycle

    /// Vend the long-lived `AppTerminalView` for a tab within `windowID`,
    /// creating one on first request. The view is added to the window's
    /// host with `isHidden = true` so it's part of the window's view
    /// hierarchy from the moment it exists — libghostty's surface (PTY +
    /// scrollback) starts up the first time it sees a non-nil `window`, and
    /// `viewDidMoveToWindow` never fires again for the life of the view.
    ///
    /// After creation, the view's `windowID` association is permanently
    /// locked. Calling this again for the same tab in a *different*
    /// `windowID` is a programmer error (cross-window reparenting is
    /// forbidden; see `view-hierarchy.md` §4).
    @discardableResult
    public func terminalView(for tab: TabRuntime, windowID: WindowID) -> AppTerminalView {
        if let existing = terminalViews[tab.id] {
            // Cross-window reparent guard: the view must already belong to
            // the expected window. A mismatch means the caller is wrong.
            if let registered = tabWindowMap[tab.id], registered != windowID {
                logger.error("terminalView(for:windowID:) tab=\(tab.id, privacy: .public) already registered in window \(registered.value, privacy: .public); ignoring windowID=\(windowID.value, privacy: .public)")
            }
            return existing
        }
        let host = hostView(forWindowID: windowID)
        let view = AppTerminalView(frame: .zero)
        view.delegate = tab.terminalDelegate
        view.controller = tab.terminal.controller
        view.configuration = tab.terminal.configuration
        view.isHidden = true
        view.autoresizingMask = []
        view.translatesAutoresizingMaskIntoConstraints = true
        host.addSubview(view)
        terminalViews[tab.id] = view
        tabWindowMap[tab.id] = windowID
        tabRuntimes[tab.id] = WeakTabRuntime(tab)
        tab.terminalNSView = view
        logger.debug("created terminal view for tab \(tab.id, privacy: .public) in window \(windowID.value, privacy: .public); host has \(self.terminalViews.count, privacy: .public) view(s)")
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
    /// Used by tests; production code goes through `terminalView(for:windowID:)`.
    func hasTerminalView(forTabID id: UUID) -> Bool {
        terminalViews[id] != nil
    }

    /// The number of live Terminal Sessions across every window — one per
    /// registered `AppTerminalView`, visible or hidden in a background Tab.
    /// Used by the footprint warning to state how many are open alongside
    /// the memory number, so the user has something actionable to close.
    public var terminalSessionCount: Int {
        terminalViews.count
    }

    /// The most-recently-applied placement for `id`, or `nil` if no placement
    /// has been set for this tab. Used by unit tests to verify that hide/show
    /// paths drive the store correctly.
    func placement(forTabID id: UUID) -> Placement? {
        placements[id]
    }

    /// Remove and release the terminal view for `tabID`. Called only when
    /// the tab is being closed for real — directly by every close path
    /// (`PaneRuntime.removeTab`, `PaneRuntime.closeOtherTabs`,
    /// `WindowRuntime.closePane`, `WindowRuntime.removeSession`,
    /// `RootWindowView`'s window-close cascade) so this is the single
    /// choke point for surface teardown.
    ///
    /// **Forces `ghostty_surface_free` synchronously (#0289).**
    /// `TerminalSurfaceCoordinator` — the type that actually owns
    /// `ghostty_surface_free` — is `internal` to `GhosttyTerminal`, so
    /// Batty can't call its `freeSurface()` directly. But
    /// `AppTerminalView.controller` (the property this store already
    /// uses to attach a view to its tab's `TerminalController`) is
    /// `open`, and its setter forwards to the coordinator's `controller`,
    /// whose `didSet` tears the surface down (`surface?.free()`, i.e.
    /// `ghostty_surface_free`) *before* checking whether the new value is
    /// non-nil. Setting it to `nil` here is therefore a real, synchronous
    /// teardown call, not a hint — this is the deterministic free the
    /// issue asks for, not a proxy for one. It's safe to call
    /// unconditionally: `TerminalSurface.free()` guards on `hasBeenFreed`,
    /// so a tab whose surface was never created (or already freed) is a
    /// no-op. The PTY dies as part of this same call — it belongs to the
    /// surface, not the ghostty app.
    ///
    /// **This does not free the ghostty app.** `TabRuntime.terminal` (a
    /// `TerminalViewState`) holds its own strong reference to the same
    /// `TerminalController` — independent of the view — and
    /// `TerminalController.deinit` is what calls `ghostty_app_free`,
    /// gated on `TabRuntime` itself deallocating. Batty creates one
    /// `ghostty_app_t` per Tab, owning its own glyph-atlas cache
    /// (`issues/0285/investigation-source.md`), so a SwiftUI reference
    /// that outlives this call (`TerminalPlaceholderView.tab`, a stuck
    /// rename sheet) still defers that free — same as before #0289, and
    /// out of this method's reach; #0287 is where a shared-controller
    /// design would close that gap. `terminalNSView` is still nil'd here
    /// for reference hygiene (no stale reads of a torn-down view through
    /// `TabRuntime`), not because it's what frees anything now.
    /// `verifyReferenceHygiene` below reports on both objects' lifetimes
    /// as a diagnostic, after the surface free above has already
    /// happened.
    ///
    /// Idempotent: a tab whose view was never created, or one already
    /// released, is a no-op (the guard returns before touching anything).
    public func releaseTerminalView(forTabID id: UUID) {
        guard let view = terminalViews.removeValue(forKey: id) else {
            logger.debug("releaseTerminalView tab=\(id, privacy: .public): no view registered (already released, or never created)")
            return
        }
        placements.removeValue(forKey: id)
        let tab = tabRuntimes.removeValue(forKey: id)?.runtime
        tabWindowMap.removeValue(forKey: id)
        view.controller = nil
        view.removeFromSuperview()
        tab?.terminalNSView = nil
        logger.debug("released terminal view for tab \(id, privacy: .public): surface and PTY freed synchronously; host has \(self.terminalViews.count, privacy: .public) view(s) remaining")
        Self.verifyReferenceHygiene(view: view, tab: tab, tabID: id)
    }

    /// Diagnostic-only follow-up to ``releaseTerminalView(forTabID:)``.
    /// Nothing here gates or affects teardown — the surface and PTY are
    /// already gone by the time this runs, forced synchronously above.
    ///
    /// - The `AppTerminalView` probe is reference hygiene, not a teardown
    ///   signal: since `view.controller = nil` already ran, nothing
    ///   further depends on when (or whether) the view itself
    ///   deallocates.
    /// - The `TabRuntime` probe is the one that says something real: it's
    ///   what still owns `TerminalController` (the per-Tab `ghostty_app_t`
    ///   and its glyph atlas) after this call. A hit here shortly after
    ///   close is *expected*, not a bug — SwiftUI is documented to keep a
    ///   just-closed tab's `TabRuntime` alive for a render pass or two
    ///   (`TerminalPlaceholderView`, `PaneView`, a rename sheet), so this
    ///   checks after a half-second delay (several render passes, not
    ///   one runloop turn) and logs at `.notice`, not `.warning`, even
    ///   then — nothing here has enough information to distinguish
    ///   "still draining" from "actually stuck" off a single sample.
    ///   Repeated notices across *multiple, unrelated* tab closes is the
    ///   real signal to chase, not one line on one close.
    ///
    /// `weak` probes are required rather than checking inside
    /// `releaseTerminalView` itself: Swift's debug-build ARC keeps a
    /// local `let`/parameter alive until its *lexical* scope ends, so a
    /// same-function check would still see a live reference regardless
    /// of what's actually true. The delay also clears AppKit's
    /// autorelease pool, which briefly holds an extra reference to any
    /// layer-backed `NSView` as a side effect of `wantsLayer = true`
    /// (`AppTerminalView.commonInit`) — the same mechanism
    /// `StableTerminalSurfaceTests`'s explicit `autoreleasepool` works
    /// around in the synchronous unit-test harness, where nothing drains
    /// a pool between statements the way a live run loop does.
    private static func verifyReferenceHygiene(view: AppTerminalView, tab: TabRuntime?, tabID: UUID) {
        weak var viewProbe = view
        weak var tabProbe = tab
        let hadTabRuntime = tab != nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if viewProbe != nil {
                logger.debug("AppTerminalView for tab \(tabID, privacy: .public) still referenced 0.5s after release — surface and PTY were already freed synchronously; this only affects when the NSView itself deallocates")
            }
            guard hadTabRuntime else { return }
            if tabProbe != nil {
                logger.notice("TabRuntime for tab \(tabID, privacy: .public) still referenced 0.5s after release — expected to clear shortly on its own (a rename sheet or SwiftUI placeholder can hold it briefly); repeated notices across unrelated tab closes would mean something is leaking a TabRuntime reference and keeping its ghostty app + glyph atlas alive")
            }
        }
    }

    // MARK: - Placement updates (per-window scoped)

    /// Reconcile every known terminal view in `windowID`'s host against the
    /// supplied placement map. Tabs with a placement become visible at the
    /// given frame; tabs without a placement (or with `isVisible == false`)
    /// are hidden but kept attached.
    ///
    /// Tabs owned by *other* windows are untouched: per-window scoping
    /// ensures one window's preference emissions cannot hide another window's
    /// terminals (design doc §3, amendment 4).
    public func updatePlacements(_ newPlacements: [UUID: Placement], forWindowID windowID: WindowID) {
        for (id, placement) in newPlacements {
            placements[id] = placement
        }
        // Walk only the views belonging to this window.
        for (id, view) in terminalViews where tabWindowMap[id] == windowID {
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

    // MARK: - Types

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
