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
    ///
    /// `.unavailable` (#0356) is the third real kernel signal
    /// `ProcessInspector.SampleFailure` can hand back —
    /// `.unexpected(errno:)`, an errno the design's spike never
    /// encountered and so never assigned a first-class state to. Flipped
    /// on the very first such failure, exactly like `.exited`/
    /// `.permissionDenied` above: the periodic sampling `Task` keeps
    /// retrying every tick regardless (nothing here cancels it — same as
    /// `.permissionDenied`), so a transient errno self-heals back to
    /// `.running` on the next successful sample, and a persistent one
    /// stays visibly `.unavailable` rather than freezing under a chip that
    /// keeps claiming `.running` over data that stopped moving.
    public enum RunState: Equatable, Sendable {
        case running
        case exited
        case permissionDenied
        case unavailable
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
    /// The latest sample — kept, untouched, when `runState` moves to
    /// `.exited` or `.unavailable` (#0356), so the view can show "what it
    /// was," not a blank space (design §3.5's tombstone banner; #0356's
    /// unavailable banner reuses the same shape). `.exited`'s displayed
    /// time (`snapshot?.capturedAt`) is therefore the real
    /// last-successful-sample instant, never a fabricated one (review
    /// round 1, B5). **`.permissionDenied` is different**: that branch in
    /// `sample(pid:)` *replaces* `snapshot` with a freshly-resolved,
    /// identity-only `Snapshot` (all metrics `nil`) rather than leaving
    /// the prior one in place.
    public private(set) var snapshot: Snapshot?
    /// `true` when no target resolves at all — no pinned pid, no
    /// followable terminal Tab (§2's "No process selected" state).
    /// Distinct from `runState`, which describes a *resolved* target's
    /// condition.
    public private(set) var hasNoSelection: Bool

    public var lifecyclePhase: PaneLifecyclePhase { controller.phase }

    private let controller = PaneLifecycleController()
    private let tabLookup: (UUID) -> TabRuntime?
    /// Sampling cadence (design: 1 second). Injectable so
    /// `ProcessStatusPaneContentTests`/`ProcessStatusPaneLifecycleWiringTests`
    /// can exercise the real periodic-resume/periodic-suspend behavior
    /// without a real 1s (or, for the negative "nothing sampled while
    /// hidden" assertion, several-seconds) wait per test — the same
    /// injectable-cadence seam `GitStatusPaneContent.debounceNanoseconds`
    /// already uses for its own timer.
    private let samplingInterval: Duration
    /// Injectable so `ProcessStatusPaneContentTests` can drive
    /// `.failure(.unexpected(errno:))` deterministically (#0356) — no live
    /// process reliably produces that errno, so tests inject it instead of
    /// hunting for one. Defaults to the real `ProcessInspector.coreMetrics`,
    /// following the same protocol/closure-with-a-real-default seam
    /// `GitStatusPaneContent` already uses for `scanner`/`watcherFactory`.
    private let coreMetricsProvider: @MainActor (pid_t) -> Result<ProcessInspector.CoreMetrics, ProcessInspector.SampleFailure>
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
    /// The errno last logged at `.error` for the current `.unavailable`
    /// run — lets `sample(pid:)` tell "just became unavailable" and "the
    /// failure reason itself changed" (both worth an `.error` line) apart
    /// from "same failure, same tick as before" (logged at `.debug`
    /// instead, so a stuck pane doesn't spam Console.app once per second).
    /// Only cleared on recovery (the `.success` branch), not on every other
    /// way out of `.unavailable` — that's sufficient because every other
    /// exit (`retarget(to:)` back to `.running`, or a later sample landing
    /// on `.exited`/`.permissionDenied`) already changes `runState` away
    /// from `.unavailable`, so the `.unexpected` branch's own
    /// `runState != .unavailable` check logs at `.error` on the next
    /// failure regardless of whatever errno is left over in this property.
    private var lastUnavailableErrno: Int32?

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

    /// Testability hook only (`internal`) — review round 2, N3: every test
    /// that constructs a `ProcessStatusPaneContent` now injects a short
    /// cadence (so the production `.seconds(1)` default itself is never
    /// exercised timing-wise), so nothing previously pinned that default
    /// directly. `ProcessStatusPaneContentTests` reads this once, on a
    /// default-initialized instance, to catch a regression to the default
    /// argument instantly rather than relying on any real wait to notice.
    var samplingIntervalForTesting: Duration { samplingInterval }

    /// Testability hook only (`internal`) — forces one `performSample()`
    /// call synchronously, so a test can control exactly when a sample
    /// happens (e.g. immediately after a real busy-loop or a real
    /// spawned process's exit) instead of waiting on the 1s `Task` timer
    /// or going through `setVisible`, which resets the CPU baseline.
    func sampleNowForTesting() {
        performSample()
    }

    /// `tabLookup` has no default: resolving a `.followingTab` target —
    /// including one chosen later through ``retarget(to:)``, which reuses
    /// this same closure rather than taking a fresh one — depends entirely
    /// on it. A nil-returning lookup tombstones every such target as
    /// `.sourceTabGone`, so every caller must supply a real one, even a
    /// target that will never invoke it (`.pinned`/`nil`).
    public init(
        target: Target?,
        tabLookup: @escaping (UUID) -> TabRuntime?,
        samplingInterval: Duration = .seconds(1),
        coreMetricsProvider: @escaping @MainActor (pid_t) -> Result<ProcessInspector.CoreMetrics, ProcessInspector.SampleFailure> = ProcessInspector.coreMetrics
    ) {
        self.target = target
        self.hasNoSelection = target == nil
        self.tabLookup = tabLookup
        self.samplingInterval = samplingInterval
        self.coreMetricsProvider = coreMetricsProvider
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
        let interval = samplingInterval
        samplingTask = Task { [weak self] in
            while true {
                try? await Task.sleep(for: interval)
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
        switch coreMetricsProvider(pid) {
        case .success(let metrics):
            if runState == .unavailable {
                logger.info("process-status: pid=\(pid, privacy: .public) recovered from unavailable")
            }
            runState = .running
            lastUnavailableErrno = nil
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
            // #0356: an unrecognized errno is no longer log-only. It must
            // not leave `runState`/`snapshot` untouched — that was exactly
            // the bug (the chip kept claiming `.running` over a frozen
            // sample with no evidence sampling was still working). The
            // last-known `snapshot` is deliberately left in place (not
            // cleared), matching `.exited` above: "what it was," not a
            // blank space. `cpuTracker` is reset so a later recovery
            // doesn't delta CPU time across an arbitrarily long gap of
            // skipped samples. The periodic sampling `Task` is left
            // running (no `cancel()` here, unlike the `.processNotFound`
            // branch) so a transient errno self-heals to `.running` on its
            // own next successful tick.
            //
            // Logged at `.error` only on the transition into `.unavailable`
            // (or when a persistent failure's errno itself changes) —
            // every tick of an already-`.unavailable` pane hitting the same
            // errno logs at `.debug` instead, so a stuck pane doesn't spam
            // Console.app once per second for as long as it stays broken.
            if runState != .unavailable || lastUnavailableErrno != code {
                logger.error("process-status: pid=\(pid, privacy: .public) unavailable — unexpected errno=\(code, privacy: .public)")
            } else {
                logger.debug("process-status: pid=\(pid, privacy: .public) still unavailable — errno=\(code, privacy: .public)")
            }
            lastUnavailableErrno = code
            runState = .unavailable
            cpuTracker.reset()
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
