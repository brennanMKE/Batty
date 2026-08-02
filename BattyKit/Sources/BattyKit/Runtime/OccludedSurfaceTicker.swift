// OccludedSurfaceTicker.swift

import Foundation
import OSLog

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "OccludedSurfaceTicker")

/// Periodically drains libghostty's queued actions for occluded Tabs that
/// `setSurfaceVisible(false)` would otherwise silence entirely (#0288).
///
/// **Why this exists.** `AppTerminalView.setSurfaceVisible(false)` sets
/// `TerminalSurfaceCoordinator.isDisplayVisible`, which feeds
/// `canRenderFrame`, which the coordinator installs as
/// `TerminalController.shouldProcessWakeup` (package-internal — Batty
/// cannot read or override it). `TerminalController.handleWakeup()` guards
/// on that closure and skips `ghostty_app_tick(app)` **entirely** when it's
/// false, which suppresses not just the render action but every queued
/// action for that Tab's `ghostty_app_t` — `RING_BELL`, `SET_TITLE`,
/// `CELL_SIZE`, `PROGRESS_REPORT`, command-finished, desktop notifications.
/// A hidden Tab producing a bell would never post it to the Bell Feed until
/// the Tab became visible again — unacceptable, since background Tabs
/// producing output while unwatched is exactly the Bell Feed's purpose.
///
/// **The fix Batty *can* make.** `TerminalController.tick()` — three lines
/// above `handleWakeup` in the same file — is `public` and has exactly one
/// caller in the whole `GhosttyTerminal` package: `handleWakeup` itself.
/// Calling it directly from Batty bypasses the wakeup gate and drains the
/// surface's action queue, delivering every action to
/// `TerminalCallbackBridge.handleAction` unconditionally — bells, titles,
/// notifications, and all the rest are dispatched straight to their
/// delegate methods with no visibility check anywhere in that path. Only
/// `GHOSTTY_ACTION_RENDER` re-enters gated code: its handler calls
/// `TerminalSurfaceCoordinator.requestImmediateTick()`, which sets a flag
/// and calls `scheduleTickIfNeeded()` — that guards on `canRenderFrame` and
/// returns immediately when occluded, so no drawable is acquired and no
/// frame is drawn. Ticking an occluded surface this way costs one C call
/// plus whatever Swift delegate callbacks fire for genuinely pending
/// actions — no GPU work, no `CAMetalLayer` involvement.
///
/// **Why this has to be a poll, not a push.** The Zig core already has a
/// real, event-driven wakeup — `wakeup_cb` fires on the main thread the
/// moment a surface has pending work, which is exactly the signal a
/// push-based design would want. But Batty has no way to observe it: the
/// callback that receives it (`TerminalController.handleWakeup`) is
/// package-internal, and the two closures that could tell Batty "a wakeup
/// happened" — `shouldProcessWakeup` and `onWakeup` — are both
/// package-internal *and* already claimed by
/// `TerminalSurfaceCoordinator.rebuildIfReady`, which overwrites them the
/// moment a surface is created. There is no public hook left to attach a
/// second observer to, and no lower-level signal (the PTY master fd, an
/// action-queue-depth counter) is exposed through the public API either.
/// `TerminalController.tick()` is the only public surface left, and it
/// carries no "is there anything to drain" signal of its own — calling it
/// is the only way to find out. Polling is therefore not a shortcut taken
/// in place of a better design; it is what remains once every event-driven
/// path turns out to be internal to the package.
///
/// **Interval: 500 ms.** The thing being optimized is bell/notification
/// latency for a Tab nobody is looking at, not frame smoothness — the
/// parked #0288 investigation used "arrives within ~1 s" as the bar for "the
/// branch is fine." 500 ms keeps worst-case added latency at half that bar
/// with headroom, while costing far less than it sounds: each tick is a
/// queue drain, not a render (no `CAMetalLayer`, no drawable, no GPU), so
/// ticking even a few dozen occluded Tabs twice a second is negligible next
/// to the cost of rendering a single visible frame. A slower interval (2 s+)
/// would still be cheap but risks feeling laggy for the Bell Feed's actual
/// purpose; a much faster one buys no latency win most users would notice
/// (BEL-producing programs don't emit faster than a person can read) while
/// adding wakeups for every idle occluded Tab in the process.
///
/// **Every occluded Tab is ticked, whether or not its surface has attached
/// yet.** `TerminalHostStore` computes ``setTargets(_:)``'s input purely
/// from effective visibility (Tab/Pane placement AND window occlusion —
/// see `TerminalHostStore.effectiveSurfaceVisible(placement:windowVisible:)`).
/// A Tab that's on screen is already ticking itself via the normal wakeup
/// path — double-ticking it here would be redundant, not incorrect, but the
/// visibility filter means it never happens. A Tab whose surface hasn't
/// attached yet (created directly into an occluded window, or the
/// placeholder hasn't mounted) still has a real `ghostty_app_t` from
/// construction, and `TerminalController.tick()` guards on it internally —
/// ticking it just drains an empty mailbox. An earlier version filtered
/// these out via a `hasLiveSurface` check in `TerminalHostStore`, which
/// went stale whenever a surface attached *after* the tick set was last
/// computed (#0288 round 3 review) — dropping the filter removed that
/// staleness class entirely.
///
/// **Not started automatically** (mirrors ``FootprintMonitor``): production
/// wiring (`BattyAppDelegate.applicationDidFinishLaunching`) calls
/// ``start()`` once at launch. Tests never call `start()`, so unit tests
/// never spin up a background polling loop — they drive ``tickOnce()``
/// directly instead.
@MainActor
final class OccludedSurfaceTicker {
    static let tickInterval: Duration = .milliseconds(500)

    /// Called once per tracked tab id on every tick. Production wires this
    /// (in `TerminalHostStore.init`) to resolve the tab's
    /// `TerminalController` and call `tick()` on it.
    var onTick: ((UUID) -> Void)?

    /// The tab ids currently scheduled for ticking. Read-only outside this
    /// type; ``setTargets(_:)`` is the sole mutator.
    private(set) var targets: Set<UUID> = []

    private var tickTask: Task<Void, Never>?

    /// Replaces the tracked set of occluded-but-live tab ids. Equality-gated
    /// so re-deriving an unchanged set (most placement/occlusion updates
    /// don't actually change who's occluded) doesn't do anything.
    func setTargets(_ newTargets: Set<UUID>) {
        guard newTargets != targets else { return }
        targets = newTargets
        logger.debug("targets updated count=\(newTargets.count, privacy: .public)")
    }

    /// Starts the polling loop if it isn't already running. Runs for the
    /// life of the process once started — like ``FootprintMonitor``, the
    /// loop itself is cheap enough (a sleep plus, most of the time, an
    /// empty-set no-op) that starting and stopping it around every
    /// empty/non-empty transition of ``targets`` isn't worth the added
    /// state to get right.
    func start() {
        guard tickTask == nil else { return }
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.tickInterval)
                guard !Task.isCancelled else { return }
                self?.tickOnce()
            }
        }
    }

    func stop() {
        tickTask?.cancel()
        tickTask = nil
    }

    /// Fires one tick cycle, invoking ``onTick`` for every currently
    /// tracked target. Internal (not private) so tests can drive individual
    /// ticks without waiting on the interval or starting the loop.
    func tickOnce() {
        guard !targets.isEmpty else { return }
        for id in targets {
            onTick?(id)
        }
    }
}
