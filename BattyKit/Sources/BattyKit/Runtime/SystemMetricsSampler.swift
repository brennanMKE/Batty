// SystemMetricsSampler.swift

import Foundation

/// What `SystemMetricsPaneContent` needs from a sampler — factored out so
/// tests can inject a fake that doesn't make real syscalls every tick
/// (mirrors `FootprintMonitor`'s own `footprintBytesProvider` testability
/// pattern, `BattyKit/Sources/BattyKit/Runtime/FootprintMonitor.swift`).
///
/// `async`, not `() -> SystemMetricsSnapshot`, so a conformer can be an
/// `actor` (as `SystemMetricsSampler` is) and run the sweep on its own
/// executor rather than the caller's — `SystemMetricsPaneContent.performTick()`
/// is the only caller, and it `await`s this from the main actor, hopping
/// off it for the call and back only to assign the result (#0350).
///
/// `nonisolated` on the protocol itself, not just the requirement: without
/// it, a cross-module conformer (any `BattyKitTests` fake) is inferred
/// `@MainActor` from BattyKit's package-wide default isolation baked into
/// the compiled interface, and an `actor` conformer then fails to compile
/// ("actor cannot conform to global-actor-isolated protocol") even though
/// same-module conformers like `SystemMetricsSampler` are unaffected.
public nonisolated protocol SystemMetricsSampling: AnyObject, Sendable {
    func sampleOnce() async -> SystemMetricsSnapshot
}

/// One full tick: thermal state, the SMC temperature/fan read, per-core +
/// aggregate CPU, system memory, load average, and a full process sweep
/// (`docs/design/system-metrics-view.md` §3 — every category, every tick,
/// at the measured cost of roughly 6.5ms against a 1-second budget).
///
/// Owns the two pieces of caller-side delta state (per-core and per-pid
/// CPU baselines) that `docs/design/system-metrics-view.md` §4 requires be
/// discarded on hide — `SystemMetricsPaneContent` does that by discarding
/// the whole `SystemMetricsSampler` instance and constructing a fresh one
/// on the next `active`-entry, rather than by resetting fields in place,
/// so "nothing kept across a hide" is a property of object lifetime, not
/// of remembering to clear every field. Also owns the SMC temperature-key
/// cache (#0351) on the same terms: discarded on hide like the trackers,
/// which just means the candidate walk repeats once per show rather than
/// never — the problem #0351 fixes is the walk repeating every tick.
///
/// An `actor`, not a `@MainActor` class: this is what actually moves the
/// ~6.5ms sweep off the main actor (#0350) — `sampleOnce()` runs on this
/// actor's own executor, so `SystemMetricsPaneContent.performTick()`
/// awaiting it hops off the main actor for the call and back only to
/// assign the resulting snapshot. The trackers below are this actor's own
/// isolated state, safe to mutate without a lock because only this actor's
/// executor ever touches them.
public actor SystemMetricsSampler: SystemMetricsSampling {
    private var coreCPUTracker = CoreCPUDeltaTracker()
    private var processCPUTracker = ProcessCPUDeltaTracker()
    private var temperatureKeyCache = SMCTemperatureKeyCache()

    /// Rate-limiting state for each reader's own failure logging (#0353),
    /// one gate per distinct failure category — owned here, alongside the
    /// delta trackers and the temperature-key cache above, because this
    /// actor already is the "discarded on hide, rebuilt fresh on next
    /// show" lifetime boundary every other piece of caller-owned reader
    /// state in this file uses. A fresh show re-logs the first failure of
    /// each kind rather than carrying quiet-since-last-time state across a
    /// hide, matching how `temperatureKeyCache`'s own resolution is
    /// discarded on hide.
    private var smcConnectionFailureGate = FailureLogGate<SMCConnectionFailure>()
    private var smcFanCountFailureGate = FailureLogGate<SMCProbeFailure>()
    private var hidThermalFailureGate = FailureLogGate<HIDThermalFailure>()
    private var hidThermalSession = HIDThermalReader.Session()
    private var cpuFailureGate = FailureLogGate<CPUReadFailure>()
    private var memoryFailureGate = FailureLogGate<MemoryReadFailure>()
    private var loadFailureGate = FailureLogGate<LoadReadFailure>()
    private var processListFailureGate = FailureLogGate<ProcessListFailure>()

    public init() {}

    public func sampleOnce() async -> SystemMetricsSnapshot {
        let thermalState = ProcessInfo.processInfo.thermalState
        let smc = SMCThermalReader.read(
            temperatureKeyCache: &temperatureKeyCache,
            connectionFailureGate: &smcConnectionFailureGate,
            fanCountFailureGate: &smcFanCountFailureGate,
            hidFailureGate: &hidThermalFailureGate,
            hidSession: &hidThermalSession
        )

        let coreTicks = SystemCPUReader.currentTicks(failureGate: &cpuFailureGate)
        let corePercentages = coreCPUTracker.percentages(for: coreTicks)
        // Review round 1 (#0314): `nil` (no baseline yet — the first tick
        // after creation or after every hide->show) must stay `nil` here,
        // not collapse into a fabricated `0.0` that reads as "measured
        // idle" on a busy machine. `coreCount` comes from the raw tick
        // read, not from `corePercentages?.count`, so the pane's "N cores"
        // sub-label is correct even on that same no-baseline tick.
        let aggregate = corePercentages.map { percentages in
            percentages.isEmpty ? 0 : percentages.reduce(0, +) / Double(percentages.count)
        }
        let cpu = CPUReading(aggregatePercent: aggregate, perCorePercent: corePercentages, coreCount: coreTicks.count)

        let memory = SystemMemoryReader.current(failureGate: &memoryFailureGate) ?? .unavailable
        let loadAverage = SystemLoadReader.current(failureGate: &loadFailureGate)

        let samples = ProcessMetricsReader.sampleAll(failureGate: &processListFailureGate)
        let cpuPercentages = processCPUTracker.percentages(for: samples)
        let processes = samples.map { sample in
            ProcessRow(
                pid: sample.pid,
                name: sample.name,
                path: sample.path,
                cpuPercent: cpuPercentages[sample.pid],
                physFootprintBytes: sample.physFootprintBytes
            )
        }

        return SystemMetricsSnapshot(
            thermalState: thermalState,
            smc: smc,
            cpu: cpu,
            memory: memory,
            loadAverage: loadAverage,
            processes: processes,
            sampledAt: Date()
        )
    }
}
