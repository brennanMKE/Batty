// SystemMetricsPaneContent.swift

import Foundation
import Observation
import OSLog

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "SystemMetricsPaneContent")

/// Model-owned content for a `.systemMetrics` `PaneRuntime`
/// (`docs/pane-view-lifecycle.md` §5 — hung off the pane, addressable by
/// its owner, never re-created by SwiftUI view churn). Conforms to
/// `PaneContentLifecycle` (#0303): a hidden pane's periodic sampling stops
/// and releases everything; a closed pane's teardown is synchronous and
/// deterministic; nothing here depends on `deinit`/ARC timing.
///
/// **Resource budget, stated per `issues/0314.md`'s own requirement**: one
/// `Task` while `.active`, ticking at `Self.sampleInterval` (1s,
/// `docs/design/system-metrics-view.md` §3); zero kernel handles held
/// between ticks (`SMCThermalReader.read()` opens and closes its own
/// `AppleSMC` connection within a single call); zero retained history
/// (`snapshot` is replaced wholesale each tick, never appended to); the
/// per-pid and per-core CPU delta baselines live inside the
/// `SystemMetricsSampler` this type owns, and that whole object is
/// discarded on hide/teardown and rebuilt fresh on the next
/// `active`-entry, per §4's "discard, not keep" decision.
///
/// **The sweep itself runs off the main actor (#0350).** `sampler` is a
/// `SystemMetricsSampling` (`SystemMetricsSampler` in production, an
/// `actor`); `performTick()` `await`s `sampleOnce()`, which hops onto that
/// actor's own executor for the ~6.5ms syscall/IOKit sweep and back only to
/// assign `snapshot`. `generation` guards the gap that hop opens: a sample
/// already in flight when `setVisible(false)`/`tearDown()` runs must not
/// land after resuming — `startActive()`/`stopActive()` each bump
/// `generation`, and `performTick()` discards its result if `generation`
/// moved while it was awaiting `sampleOnce()`, whether because the pane
/// suspended/tore down or because it was hidden and shown again with a
/// fresh sampler before the stale one's sample returned.
@MainActor
@Observable
public final class SystemMetricsPaneContent: PaneContentLifecycle {
    public static let sampleInterval: Duration = .seconds(1)

    /// Where each tick's sampler comes from. Defaults to a real
    /// `SystemMetricsSampler`; tests inject a fake that records calls
    /// instead of making live syscalls every tick — the same
    /// provider-closure testability `FootprintMonitor.footprintBytesProvider`
    /// already establishes for this codebase.
    public var samplerFactory: () -> SystemMetricsSampling = { SystemMetricsSampler() }

    public private(set) var snapshot: SystemMetricsSnapshot = .empty

    private let controller = PaneLifecycleController()
    private var sampler: SystemMetricsSampling?
    private var task: Task<Void, Never>?
    private var generation = 0

    public var lifecyclePhase: PaneLifecyclePhase { controller.phase }

    public init() {}

    public func setUp(visible: Bool) {
        let result = controller.apply(.setUp(visible: visible))
        guard case .applied(_, let to) = result else {
            logger.error("setUp: unexpected transition result \(String(describing: result), privacy: .public)")
            return
        }
        if to == .active {
            startActive()
        }
    }

    public func setVisible(_ visible: Bool) {
        let result = controller.apply(visible ? .show : .hide)
        switch result {
        case .applied(_, .active):
            startActive()
        case .applied(_, .suspended):
            stopActive()
        default:
            break
        }
    }

    public func tearDown() {
        let result = controller.apply(.tearDown)
        if case .applied = result {
            stopActive()
        }
    }

    /// Manual refresh affordance (`docs/design/system-metrics-view.md`
    /// §7's header refresh button). A no-op while suspended/torn-down —
    /// there is no sampler alive to ask.
    public func refreshNow() async {
        await performTick()
    }

    private func startActive() {
        generation += 1
        sampler = samplerFactory()
        task?.cancel()
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.performTick()
                try? await Task.sleep(for: Self.sampleInterval)
            }
        }
    }

    private func stopActive() {
        generation += 1
        task?.cancel()
        task = nil
        sampler = nil
    }

    /// One sampling pass. Guarded on `.active` so a stray call — the
    /// manual refresh button, or the background `Task`'s next iteration
    /// landing just after a hide — is a no-op rather than sampling with no
    /// sampler, or sampling while suspended
    /// (`docs/pane-view-lifecycle.md` §4's "suspended costs zero periodic
    /// work" contract).
    ///
    /// `sampleOnce()` runs off the main actor (see the type doc comment),
    /// so between the `await` starting and returning, `setVisible(false)`/
    /// `tearDown()`/another `startActive()` can run to completion on the
    /// main actor — the `generation` re-check after the `await` is what
    /// keeps a sample that finishes late from overwriting state a newer
    /// generation (or no longer being visible) has already moved past. Not
    /// private: unit tests drive this directly instead of waiting on the
    /// real 1-second timer, the same way `FootprintMonitor.sampleOnce()` is
    /// exposed for its own tests.
    func performTick() async {
        guard controller.phase == .active, let sampler else { return }
        let generationAtStart = generation
        let result = await sampler.sampleOnce()
        guard controller.phase == .active, generation == generationAtStart else { return }
        snapshot = result
    }

    // Deliberately no `deinit`-based cleanup: the #0289 lesson this
    // codebase already carries forward (`docs/pane-view-lifecycle.md` §5)
    // is that release must happen synchronously inside `tearDown()`, not
    // be deferred to ARC — and a `@MainActor` class's `deinit` runs
    // nonisolated in this build configuration, so it can't touch
    // `task`/`sampler` anyway. `WindowRuntime.closePane` calling
    // `pane.content?.tearDown()` is the only release path.
}
