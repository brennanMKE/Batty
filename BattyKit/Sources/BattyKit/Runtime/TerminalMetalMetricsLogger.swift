// TerminalMetalMetricsLogger.swift

import AppKit
import Foundation
import GhosttyTerminal
import OSLog

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "TerminalMetalMetricsLogger")

/// #0294 in-process confirmation instrumentation for the 2x-drawable
/// anomaly found by #0285's live investigation (a drawable class at
/// exactly 2x the content area on a 1x display). Two complementary
/// signals, both gated behind the same env var:
///
/// 1. **`GhosttyTerminal.TerminalDebugLog`'s `.metrics` category** — the
///    decisive one. Every scale-factor path in `AppTerminalView` /
///    `TerminalSurfaceCoordinator` falls back to a hardcoded `2.0` when
///    both `window` and `NSScreen.main` are nil (app inactive, screen
///    locked, displays asleep), and `synchronizeMetrics` bakes that scale
///    into the ghostty surface's pixel size at the moment it runs —
///    `setFrameSize`/`layout` route into it on every AppKit layout pass.
///    A *poll* of current `contentsScale` can miss this entirely: the
///    scale that mis-sized the surface can correct itself moments later
///    while the already-allocated 2x drawable chain stays put (nothing
///    re-triggers `synchronizeMetrics` just because the scale changed
///    back, and `TerminalHostStore.updatePlacements` only touches
///    `view.frame` for currently-visible placements, so a session
///    mis-sized once and then hidden keeps it indefinitely). Routing
///    `TerminalDebugLog`'s `.metrics` line — `sync view=WxH scale=S
///    pixels=PxP`, emitted by `synchronizeMetrics` at the instant it
///    computes a size — into this file's `Logger` captures the
///    transient scale, not just whatever the layer reads back later.
///    Only `.metrics` is enabled, never `.standard`/`.all`: those also
///    cover `.input`/`.output`, which would put keystrokes and shell
///    output into the unified log.
/// 2. **A periodic per-`AppTerminalView` dump** (below) of the
///    *currently* attached layer plus the `metalLayer` ivar
///    `AppTerminalView.commonInit` creates and `updateMetalLayerMetrics`
///    keeps writing to even after `self.layer` is swapped to a different
///    backing layer (see `docs/view-hierarchy.md` and #0293's note). This
///    is a current-state snapshot, not a moment-of-allocation capture —
///    useful for correlating a live `tools/memsample.sh` census against
///    *which* surface holds a given geometry class, but on its own it
///    can read all-1.0 while a stale 2x IOSurface chain persists from an
///    earlier transient scale, which is exactly why (1) exists.
///
/// Off by default — enabled only when `BATTY_LOG_METAL_LAYER_METRICS` is
/// set in the process environment, so ordinary Beta/Prod runs never pay
/// for it. Kept in the tree rather than deleted after #0294 lands because
/// this correlation problem will recur for any future graphics-geometry
/// anomaly; flipping the env var is cheaper than re-writing this each
/// time.
///
/// The `metalLayer` ivar itself has no public accessor (it's `internal`
/// to `GhosttyTerminal`), so (2) reads it via `Mirror` reflection rather
/// than forking the dependency: Swift access control is a compile-time-
/// only concept, and `Mirror(reflecting:)` walks the real stored-property
/// layout regardless of it. Two residual limits of that approach, both
/// handled by degrading to a legible log line rather than a wrong
/// conclusion (see ``OrphanProbe``): `Mirror` walks only
/// `AppTerminalView`'s own declared stored properties, not
/// `superclassMirror`'s, so an upstream move of `metalLayer` to a base
/// class would silently read as "no such child"; and it depends on
/// Swift's reflection metadata, which a `SWIFT_REFLECTION_METADATA_LEVEL`
/// build-setting reduction would strip.
@MainActor
public enum TerminalMetalMetricsLogger {

    public static let isEnabled: Bool = {
        ProcessInfo.processInfo.environment["BATTY_LOG_METAL_LAYER_METRICS"] != nil
    }()

    private static var loggingTask: Task<Void, Never>?

    /// Starts a periodic dump of every live terminal view's layer geometry
    /// and routes `GhosttyTerminal.TerminalDebugLog`'s `.metrics` category
    /// into this file's `Logger`. No-op unless ``isEnabled``. Idempotent —
    /// a second call while already running is a no-op. Intended call
    /// site: once from `BattyAppDelegate.applicationDidFinishLaunching`.
    public static func startIfEnabled(interval: Duration = .seconds(10)) {
        guard isEnabled, loggingTask == nil else { return }
        configureGhosttyMetricsLog()
        logger.notice("BATTY_LOG_METAL_LAYER_METRICS set; dumping terminal layer metrics every \(interval.components.seconds, privacy: .public)s; GhosttyTerminal .metrics debug log routed here")
        loggingTask = Task {
            while !Task.isCancelled {
                logOnce(reason: "periodic")
                try? await Task.sleep(for: interval)
            }
        }
    }

    /// Cancels the periodic dump and disables the ghostty debug log this
    /// enabled. Not called in production (there is no shutdown hook for
    /// an opt-in process-lifetime diagnostic), but present so the task's
    /// `while !Task.isCancelled` loop has a real cancellation path rather
    /// than implying one that doesn't exist.
    public static func stop() {
        loggingTask?.cancel()
        loggingTask = nil
        TerminalDebugLog.disable()
    }

    /// Routes only `.metrics` — never `.standard`/`.all`, which also
    /// cover `.input`/`.output` and would put keystrokes and shell output
    /// into the unified log — and replaces `TerminalDebugLog`'s default
    /// sink (`Swift.print`, forbidden by `CLAUDE.md`) with this file's
    /// `Logger`.
    private static func configureGhosttyMetricsLog() {
        TerminalDebugLog.sink = { message in
            logger.notice("\(message, privacy: .public)")
        }
        TerminalDebugLog.categories = .metrics
        TerminalDebugLog.isEnabled = true
    }

    /// One dump pass over every terminal view `TerminalHostStore` currently
    /// tracks, visible or hidden in a background tab. Internal rather than
    /// public: the periodic task above is the only production call site,
    /// and a debugger can reach an internal static func within the module
    /// it's stopped in just as well as a public one, so there's no reason
    /// to widen the module's public surface for a diagnostic entry point.
    static func logOnce(reason: String) {
        let store = TerminalHostStore.shared
        let views = store.debugAllTerminalViews()
        guard !views.isEmpty else {
            logger.debug("logOnce(\(reason, privacy: .public)): no terminal views registered")
            return
        }
        logger.notice("logOnce(\(reason, privacy: .public)): \(views.count, privacy: .public) terminal view(s)")
        for (tabID, view) in views {
            log(tabID: tabID, view: view, store: store)
        }
    }

    private static func log(tabID: UUID, view: AppTerminalView, store: TerminalHostStore) {
        let tab = store.tabRuntime(forTabID: tabID)
        let bounds = view.bounds
        let windowBackingScale = view.window?.backingScaleFactor ?? -1
        let activeLayer = view.layer
        let activeLayerClass = activeLayer.map { String(describing: type(of: $0)) } ?? "nil"
        let activeContentsScale = activeLayer?.contentsScale ?? -1
        let activeLayerBounds = activeLayer?.bounds
        // CAMetalLayer.drawableSize is only meaningful when the active
        // layer actually is one; ghostty's IOSurfaceLayer-backed render
        // path (the common case post-swap, per the type doc comment)
        // has no equivalent property, hence "n/a" there — activeLayerBounds
        // is what covers that configuration instead.
        let activeDrawableSize = (activeLayer as? CAMetalLayer)?.drawableSize

        let orphan = orphanedMetalLayer(of: view)
        let orphanIsActiveLayer = orphan.layer != nil && orphan.layer === (activeLayer as? CAMetalLayer)

        logger.notice("""
        metalMetrics tab=\(tabID, privacy: .public) \
        pane=\(tab?.paneID?.uuidString ?? "nil", privacy: .public) \
        session=\(tab?.sessionID?.uuidString ?? "nil", privacy: .public) \
        bounds=\(Self.format(bounds.width, bounds.height), privacy: .public) \
        windowBackingScale=\(windowBackingScale, privacy: .public) \
        activeLayer=\(activeLayerClass, privacy: .public) \
        activeContentsScale=\(activeContentsScale, privacy: .public) \
        activeLayerBounds=\(activeLayerBounds.map { Self.format($0.width, $0.height) } ?? "n/a", privacy: .public) \
        activeDrawableSize=\(activeDrawableSize.map { Self.format($0.width, $0.height) } ?? "n/a", privacy: .public) \
        orphanedIvarChildFound=\(orphan.childFound, privacy: .public) \
        orphanedCastToCAMetalLayerSucceeded=\(orphan.layer != nil, privacy: .public) \
        orphanedIsActiveLayer=\(orphanIsActiveLayer, privacy: .public) \
        orphanedContentsScale=\(orphan.layer.map { String(format: "%.2f", $0.contentsScale) } ?? "n/a", privacy: .public) \
        orphanedDrawableSize=\(orphan.layer.map { Self.format($0.drawableSize.width, $0.drawableSize.height) } ?? "n/a", privacy: .public)
        """)
    }

    /// Result of probing `AppTerminalView` for its `metalLayer` ivar via
    /// `Mirror`. Kept as two separate facts rather than collapsed into a
    /// single optional: "no child labelled `metalLayer`" (renamed away,
    /// removed, or on a superclass `Mirror` doesn't walk — see the type
    /// doc comment) and "child present but its value didn't cast to
    /// `CAMetalLayer`" (e.g. the stored value is genuinely `nil`) are
    /// different findings, and the anomaly this file exists to catch
    /// turns on which one occurred — a single collapsed `nil` would hide
    /// that distinction.
    private struct OrphanProbe {
        let childFound: Bool
        let layer: CAMetalLayer?
    }

    /// Reads the `metalLayer` ivar `AppTerminalView.commonInit` creates
    /// and `updateMetalLayerMetrics` keeps writing to, independent of
    /// whether it's still `self.layer`. See the type doc comment for why
    /// reflection is used instead of a public accessor, and for this
    /// approach's two residual failure modes.
    private static func orphanedMetalLayer(of view: AppTerminalView) -> OrphanProbe {
        for child in Mirror(reflecting: view).children where child.label == "metalLayer" {
            return OrphanProbe(childFound: true, layer: child.value as? CAMetalLayer)
        }
        return OrphanProbe(childFound: false, layer: nil)
    }

    private static func format(_ width: CGFloat, _ height: CGFloat) -> String {
        String(format: "%.0fx%.0f", width, height)
    }
}
