// ProcessStatusPaneContent.swift

import Foundation
import Observation
import OSLog

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "ProcessStatusPaneContent")

/// Model-owned `PaneContentLifecycle` conformer for a `.processStatus`
/// Pane (`#0305`), hung off `PaneRuntime` the way `TabRuntime.terminal`
/// hangs off `TabRuntime` (`docs/design/process-status-view.md` §0) so
/// `WindowRuntime.closePane`/`hidePane`/`showPane` can drive its lifecycle
/// directly rather than relying on SwiftUI view teardown
/// (`docs/pane-view-lifecycle.md` §5).
///
/// Samples only what the design's spike proved obtainable via libproc for
/// a same-uid target, at a 1-second cadence: CPU% (delta-computed),
/// memory footprint, thread count, open-file count. No subprocess, no
/// Mach task port — every call in `ProcessInspector` is synchronous and
/// sub-millisecond, so the sampling loop runs directly on this type's own
/// actor (MainActor, this package's default isolation) with no dispatch
/// hop.
@Observable
public final class ProcessStatusPaneContent: PaneContentLifecycle {
    /// Which process this pane tracks (`docs/design/process-status-view.md`
    /// §2). Chosen at creation and changed only via ``retarget(to:)`` —
    /// never an implicit rebind.
    public enum Target: Equatable, Sendable {
        /// A literal pid, frozen for the pane's life. Tombstones on exit
        /// (`ESRCH`); never guesses a successor.
        case pinned(pid_t)
        /// Re-resolved every tick from the named Tab's `foregroundPid`.
        /// Tombstones only when the Tab itself disappears (the lookup
        /// misses), not when a single command within it exits.
        case followingTab(UUID)
    }

    /// What the view renders for the current tick. Each case is a real
    /// kernel signal (`ESRCH`/`EPERM`/a tab-lookup miss), not an inferred
    /// guess (`docs/design/process-status-view.md` §1.4).
    ///
    /// `.exited` carries no timestamp of its own (review round 1, B5) —
    /// the design specifies showing "the timestamp of the last successful
    /// sample," which is `snapshot?.capturedAt`, not the instant this
    /// process detected the exit. The two can differ by up to one refresh
    /// interval, and for a pid that was already dead the very first time
    /// it was sampled, there is no successful sample to date at all.
    /// Carrying `Date()` here (as an earlier draft did) asserted a fact
    /// (`"Process exited at <time>"`) this type never actually observed.
    public enum RunState: Equatable, Sendable {
        case running
        case exited
        case permissionDenied
    }

    /// One tick's worth of core metrics plus the identity fields
    /// (resolved alongside them, refreshed only when they change) —
    /// bundled together because the view renders them as one header/
    /// metrics unit regardless of which changed most recently.
    public struct Snapshot: Equatable, Sendable {
        public var pid: pid_t
        public var name: String
        public var executablePath: String?
        public var commandLine: String?
        public var cpuPercent: Double?
        public var physFootprintBytes: UInt64?
        public var residentBytes: UInt64?
        public var threadCount: Int?
        public var openFileCount: Int?
        public var capturedAt: Date
    }

    private enum Resolution {
        case pid(pid_t)
        case noSelection
        case sourceTabGone
    }

    public private(set) var target: Target?
    public private(set) var runState: RunState = .running
    /// The latest sample — kept even after `runState` moves to
    /// `.exited`/`.permissionDenied` so the view can show "what it was,"
    /// not a blank space (design §3.5/§3.6's tombstone/permission
    /// banners), and so `.exited`'s displayed time
    /// (`snapshot?.capturedAt`) is the real last-successful-sample instant
    /// rather than a fabricated one (review round 1, B5).
    public private(set) var snapshot: Snapshot?
    /// `true` when no target resolves at all — no pinned pid, no
    /// followable terminal Tab (§2's "No process selected" state).
    /// Distinct from `runState`, which describes a *resolved* target's
    /// condition.
    public private(set) var hasNoSelection: Bool

    public var lifecyclePhase: PaneLifecyclePhase { controller.phase }

    private let controller = PaneLifecycleController()
    private let tabLookup: (UUID) -> TabRuntime?
    private var samplingTask: Task<Void, Never>?
    /// `#0314` merge: the pid-keyed CPU-delta baseline (review round 1,
    /// B2 — mode B's followed pid changes tick to tick, and delta-ing
    /// process B's current CPU time against process A's previous sample
    /// produces a meaningless bogus value) is now the shared
    /// `ProcessCPUDeltaTracker` (`ProcessCPUDeltaTracker.swift`, #0314)
    /// instead of a hand-rolled dictionary-of-one — the same type #0314's
    /// whole-system view uses for every row, fed one `ProcessSample` at a
    /// time here. A pid absent from one call's `samples` simply doesn't
    /// appear in the tracker's next internal baseline, which is exactly
    /// "reset on pid change" for a single-sample-per-tick caller like
    /// this one.
    private var cpuTracker = ProcessCPUDeltaTracker()

    /// Testability hook only (`internal`, reached via `@testable import`
    /// in `BattyKitTests`) — lets a test assert the sampling `Task` is
    /// actually gone after hide/teardown, not merely that observable
    /// state stopped changing. Review round 1's own test-gap finding:
    /// removing `stopSampling()` from the hide path left
    /// `aHiddenProcessStatusPaneDoesNotKeepSampling` passing anyway,
    /// because the loop's `lifecyclePhase == .active` guard alone was
    /// enough to satisfy that test — a leaked once-per-second-waking
    /// `Task` would have gone undetected.
    var isSamplingTaskAlive: Bool { samplingTask != nil }

    /// Testability hook only (`internal`) — forces one `performSample()`
    /// call synchronously, so a test can control exactly when a sample
    /// happens (e.g. immediately after a real busy-loop or a real
    /// spawned process's exit) instead of waiting on the 1s `Task` timer
    /// or going through `setVisible`, which resets the CPU baseline.
    func sampleNowForTesting() {
        performSample()
    }

    public init(target: Target?, tabLookup: @escaping (UUID) -> TabRuntime? = { _ in nil }) {
        self.target = target
        self.hasNoSelection = target == nil
        self.tabLookup = tabLookup
    }

    // MARK: - PaneContentLifecycle

    public func setUp(visible: Bool) {
        let result = controller.apply(.setUp(visible: visible))
        guard case .applied(_, .active) = result else { return }
        startSampling()
    }

    public func setVisible(_ visible: Bool) {
        let result = controller.apply(visible ? .show : .hide)
        switch result {
        case .applied(_, .active):
            startSampling()
        case .applied(_, .suspended):
            stopSampling()
        default:
            break
        }
    }

    public func tearDown() {
        let result = controller.apply(.tearDown)
        guard case .applied = result else { return }
        stopSampling()
    }

    // MARK: - Retargeting (§2's "Choose Process…")

    /// Tears down whatever sampling was running for the old target and
    /// re-runs identity resolution against the new one — the same
    /// "one-time resolution, explicit re-trigger" shape
    /// `docs/design/git-status-view.md` uses for its own retarget action.
    public func retarget(to newTarget: Target?) {
        stopSampling()
        target = newTarget
        hasNoSelection = newTarget == nil
        runState = .running
        snapshot = nil
        guard lifecyclePhase == .active else { return }
        startSampling()
    }

    /// §3.4's "Watch this instead" affordance on a child-process row —
    /// pivots straight to mode A pinned on that pid.
    public func watchInstead(pid: pid_t) {
        retarget(to: .pinned(pid))
    }

    // MARK: - Sampling

    /// Starts (or resumes) the 1s sampling loop. Guarded on `runState`
    /// *twice* — once before the immediate sample, once after (review
    /// round 1, B4): the immediate `performSample()` call below can
    /// itself discover the target is gone and tombstone mid-call, and
    /// without the second guard this function would go on to schedule a
    /// fresh periodic `Task` anyway, which would then re-detect the same
    /// exit a second time roughly a tick later — proved empirically: a
    /// pane pinned to an already-exited pid tombstoned once at the
    /// immediate sample, then again ~1s later with a *later* timestamp,
    /// silently overwriting the first (and, pre-B5-fix, correct) exit
    /// time. "Stops sampling — there is nothing left to sample" (the
    /// design's own words) means exactly that: no further `performSample`
    /// call of any kind once `.exited`.
    private func startSampling() {
        guard samplingTask == nil else { return }
        if case .exited = runState { return }
        performSample()
        if case .exited = runState { return }
        samplingTask = Task { [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                if Task.isCancelled { return }
                guard self.lifecyclePhase == .active else { return }
                self.performSample()
            }
        }
    }

    private func stopSampling() {
        samplingTask?.cancel()
        samplingTask = nil
        cpuTracker.reset()
    }

    private func resolveTarget() -> Resolution {
        switch target {
        case .pinned(let pid):
            return .pid(pid)
        case .followingTab(let tabID):
            guard let tab = tabLookup(tabID) else { return .sourceTabGone }
            guard let pid = tab.terminalNSView?.foregroundPid else { return .noSelection }
            return .pid(pid)
        case nil:
            return .noSelection
        }
    }

    private func performSample() {
        switch resolveTarget() {
        case .sourceTabGone:
            logger.info("process-status: followed tab gone, tombstoning")
            runState = .exited
            hasNoSelection = false
            samplingTask?.cancel()
            samplingTask = nil
        case .noSelection:
            hasNoSelection = true
        case .pid(let pid):
            hasNoSelection = false
            sample(pid: pid)
        }
    }

    private func sample(pid: pid_t) {
        switch ProcessInspector.coreMetrics(pid: pid) {
        case .success(let metrics):
            runState = .running
            let identity = ProcessInspector.identity(pid: pid)
            let commandLine = try? ProcessInspector.commandLine(pid: pid).get()
            let name = identity.name ?? basename(of: identity.executablePath) ?? "pid \(pid)"
            let processSample = ProcessSample(
                pid: pid,
                name: name,
                path: identity.executablePath,
                threadCount: metrics.threadCount,
                physFootprintBytes: metrics.physFootprintBytes,
                residentSizeBytes: metrics.residentBytes,
                cpuTicksUser: metrics.cpuTicksUser,
                cpuTicksSystem: metrics.cpuTicksSystem
            )
            snapshot = Snapshot(
                pid: pid,
                name: name,
                executablePath: identity.executablePath,
                commandLine: commandLine,
                cpuPercent: cpuPercent(for: processSample),
                physFootprintBytes: metrics.physFootprintBytes,
                residentBytes: metrics.residentBytes,
                threadCount: metrics.threadCount,
                openFileCount: metrics.openFileCount,
                capturedAt: Date()
            )
        case .failure(.processNotFound):
            // Deliberately does not touch `snapshot` — the last
            // successful sample (if any) stays put, and its
            // `capturedAt` is what `.exited` displays (B5).
            logger.info("process-status: pid=\(pid, privacy: .public) exited")
            runState = .exited
            cpuTracker.reset()
            samplingTask?.cancel()
            samplingTask = nil
        case .failure(.permissionDenied):
            // §1.6: identity sits behind a looser permission tier than
            // metrics — `proc_pidpath` can still resolve here even though
            // `coreMetrics` just failed. `proc_name` shares metrics'
            // tier, so the name falls back to the path's basename rather
            // than a second guess, and `commandLine` (`KERN_PROCARGS2`,
            // the same tier as metrics) is never populated in this branch.
            runState = .permissionDenied
            cpuTracker.reset()
            let identity = ProcessInspector.identity(pid: pid)
            snapshot = Snapshot(
                pid: pid,
                name: identity.name ?? basename(of: identity.executablePath) ?? "pid \(pid)",
                executablePath: identity.executablePath,
                commandLine: nil,
                cpuPercent: nil,
                physFootprintBytes: nil,
                residentBytes: nil,
                threadCount: nil,
                openFileCount: nil,
                capturedAt: Date()
            )
        case .failure(.unexpected(let code)):
            logger.error("process-status: unexpected sample failure pid=\(pid, privacy: .public) errno=\(code, privacy: .public)")
        }
    }

    /// `#0314` merge: delegates to the shared `ProcessCPUDeltaTracker`
    /// instead of a hand-rolled per-pid baseline. `internal` (not
    /// `private`) deliberately — `ProcessStatusPaneContentTests` feeds
    /// synthetic `ProcessSample`s with different pids directly to prove
    /// the cross-pid reset (review round 1, B2) through this exact
    /// integration point, rather than only indirectly through mode B,
    /// which needs a live AppKit `foregroundPid` this headless test
    /// target can't produce.
    func cpuPercent(for sample: ProcessSample) -> Double? {
        cpuTracker.percentages(for: [sample])[sample.pid]
    }

    private func basename(of path: String?) -> String? {
        guard let path else { return nil }
        return (path as NSString).lastPathComponent
    }

    // MARK: - On-demand disclosures (§1.7/§3.4 — never per-tick)

    public func openFiles() -> [ProcessInspector.OpenFileDescriptor] {
        guard let pid = snapshot?.pid else { return [] }
        return ProcessInspector.listOpenFileDescriptors(pid: pid) ?? []
    }

    public func childProcesses() -> [ProcessInspector.ChildProcess] {
        guard let pid = snapshot?.pid else { return [] }
        return ProcessInspector.children(ofPid: pid)
    }
}
