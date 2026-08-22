// SystemMetricsSampler.swift

import Foundation

/// What `SystemMetricsPaneContent` needs from a sampler — factored out so
/// tests can inject a fake that doesn't make real syscalls every tick
/// (mirrors `FootprintMonitor`'s own `footprintBytesProvider` testability
/// pattern, `BattyKit/Sources/BattyKit/Runtime/FootprintMonitor.swift`).
public protocol SystemMetricsSampling: AnyObject {
    func sampleOnce() -> SystemMetricsSnapshot
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
/// of remembering to clear every field.
public final class SystemMetricsSampler: SystemMetricsSampling {
    private var coreCPUTracker = CoreCPUDeltaTracker()
    private var processCPUTracker = ProcessCPUDeltaTracker()

    public init() {}

    public func sampleOnce() -> SystemMetricsSnapshot {
        let thermalState = ProcessInfo.processInfo.thermalState
        let smc = SMCThermalReader.read()

        let coreTicks = SystemCPUReader.currentTicks()
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

        let memory = SystemMemoryReader.current() ?? .unavailable
        let loadAverage = SystemLoadReader.current()

        let samples = ProcessMetricsReader.sampleAll()
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
