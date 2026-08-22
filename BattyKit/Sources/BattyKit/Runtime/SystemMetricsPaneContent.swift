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
    public func refreshNow() {
        performTick()
    }

    private func startActive() {
        sampler = samplerFactory()
        task?.cancel()
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.performTick()
                try? await Task.sleep(for: Self.sampleInterval)
            }
        }
    }

    private func stopActive() {
        task?.cancel()
        task = nil
        sampler = nil
    }

    /// One sampling pass. Guarded on `.active` so a stray call — the
    /// manual refresh button, or the background `Task`'s next iteration
    /// landing just after a hide — is a no-op rather than sampling with no
    /// sampler, or sampling while suspended
    /// (`docs/pane-view-lifecycle.md` §4's "suspended costs zero periodic
    /// work" contract). Not private: unit tests drive this directly
    /// instead of waiting on the real 1-second timer, the same way
    /// `FootprintMonitor.sampleOnce()` is exposed for its own tests.
    func performTick() {
        guard controller.phase == .active, let sampler else { return }
        snapshot = sampler.sampleOnce()
    }

    // Deliberately no `deinit`-based cleanup: the #0289 lesson this
    // codebase already carries forward (`docs/pane-view-lifecycle.md` §5)
    // is that release must happen synchronously inside `tearDown()`, not
    // be deferred to ARC — and a `@MainActor` class's `deinit` runs
    // nonisolated in this build configuration, so it can't touch
    // `task`/`sampler` anyway. `WindowRuntime.closePane` calling
    // `pane.content?.tearDown()` is the only release path.
}
