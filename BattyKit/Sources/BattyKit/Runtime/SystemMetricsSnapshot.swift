// SystemMetricsSnapshot.swift

import Foundation

/// Aggregate + per-core CPU utilization for one tick.
///
/// **`aggregatePercent`/`perCorePercent` are `nil`, never `0`, whenever no
/// delta baseline exists yet** — review round 1 (#0314) caught the
/// original version of this type laundering `CoreCPUDeltaTracker`'s
/// correct "no baseline" `nil` into a fabricated `0.0%`, which read as a
/// real (and wrong) measurement on the pane's first tick and after every
/// hide→show, on a machine that was actually busy. `coreCount` is tracked
/// separately, from the raw tick read (`SystemCPUReader.currentTicks(failureGate:)`),
/// so the core-count sub-label stays correct even on the one tick where
/// no percentage exists yet — it is not derived from
/// `perCorePercent?.count`, which would report `0` cores on that same
/// tick and be just as wrong as the fabricated percentage was.
public nonisolated struct CPUReading: Equatable, Sendable {
    public let aggregatePercent: Double?
    public let perCorePercent: [Double]?
    public let coreCount: Int

    public init(aggregatePercent: Double?, perCorePercent: [Double]?, coreCount: Int) {
        self.aggregatePercent = aggregatePercent
        self.perCorePercent = perCorePercent
        self.coreCount = coreCount
    }

    public static let unavailable = CPUReading(aggregatePercent: nil, perCorePercent: nil, coreCount: 0)
}

/// One process-list row, already resolved to view-ready values —
/// `docs/design/system-metrics-view.md` §2/§7's three-tier name fallback
/// and "denied is '—', never 0" rule are applied by the time this type
/// exists; the view renders it, it doesn't re-derive it.
public nonisolated struct ProcessRow: Identifiable, Equatable, Sendable {
    public var id: pid_t { pid }
    public let pid: pid_t
    public let name: String
    public let path: String?
    /// `nil` means "no baseline yet or denied" — the view renders "—".
    public let cpuPercent: Double?
    /// `nil` means "denied" (`ProcessSample.isOwnershipDenied`) — the view
    /// renders "—", never `0`.
    public let physFootprintBytes: UInt64?

    public init(pid: pid_t, name: String, path: String?, cpuPercent: Double?, physFootprintBytes: UInt64?) {
        self.pid = pid
        self.name = name
        self.path = path
        self.cpuPercent = cpuPercent
        self.physFootprintBytes = physFootprintBytes
    }
}

/// Everything one sampling tick produces
/// (`docs/design/system-metrics-view.md` §3: thermal state, the five
/// system-wide numbers, the process sweep, and the SMC read, all taken
/// together as one tick's worth of data).
///
/// `nonisolated`, like `CPUReading`/`ProcessRow` above: `SystemMetricsSampler`
/// constructs these off the main actor, so their initializers must not
/// inherit BattyKit's package-wide default `MainActor` isolation.
public nonisolated struct SystemMetricsSnapshot: Equatable, Sendable {
    public let thermalState: ProcessInfo.ThermalState
    public let smc: SMCThermalReading
    public let cpu: CPUReading
    public let memory: MemoryReading
    public let loadAverage: LoadAverage
    public let processes: [ProcessRow]
    public let sampledAt: Date?

    public init(
        thermalState: ProcessInfo.ThermalState,
        smc: SMCThermalReading,
        cpu: CPUReading,
        memory: MemoryReading,
        loadAverage: LoadAverage,
        processes: [ProcessRow],
        sampledAt: Date?
    ) {
        self.thermalState = thermalState
        self.smc = smc
        self.cpu = cpu
        self.memory = memory
        self.loadAverage = loadAverage
        self.processes = processes
        self.sampledAt = sampledAt
    }

    /// The pre-first-sample state — `SystemMetricsPaneContent` starts here
    /// and replaces it with a real snapshot as soon as `setUp`/`setVisible`
    /// lands on `.active` and performs its first tick.
    public static let empty = SystemMetricsSnapshot(
        thermalState: .nominal,
        smc: .unavailable,
        cpu: .unavailable,
        memory: .unavailable,
        loadAverage: .zero,
        processes: [],
        sampledAt: nil
    )
}
