// SystemCPUReader.swift

import Darwin
import Foundation

/// One core's cumulative tick counters from `host_processor_info`. Raw
/// counters, not a percentage — `SystemCPUReader.percentages(from:to:)`
/// turns two consecutive reads into a per-core utilization percentage.
public nonisolated struct CoreTicks: Equatable, Sendable {
    public let user: UInt32
    public let system: UInt32
    public let idle: UInt32
    public let nice: UInt32

    public init(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32) {
        self.user = user
        self.system = system
        self.idle = idle
        self.nice = nice
    }

    var total: UInt64 { UInt64(user) + UInt64(system) + UInt64(idle) + UInt64(nice) }
    var busy: UInt64 { UInt64(user) + UInt64(system) + UInt64(nice) }
}

/// Reads per-core CPU ticks via `host_processor_info(PROCESSOR_CPU_LOAD_INFO)`
/// (`docs/design/system-metrics-view.md` §1.6/§2 — free, sub-millisecond,
/// 12 cores on the spike's Mac mini M4). Stateless: each call is an
/// independent snapshot; the caller (`CoreCPUDeltaTracker`) holds the prior
/// snapshot needed to compute a percentage.
///
/// `nonisolated` because BattyKit's package-wide default actor isolation is
/// `MainActor` — without this, every call here would silently require the
/// main actor, defeating `SystemMetricsSampler`'s whole point of running
/// this sweep on its own executor.
public nonisolated enum SystemCPUReader {
    public static func currentTicks() -> [CoreTicks] {
        var cpuInfo: processor_info_array_t!
        var numCpuInfo: mach_msg_type_number_t = 0
        var numCpus: natural_t = 0
        let hostPort = mach_host_self()
        // Review round 1 (#0314): mach_host_self() returns an owned send
        // right (matching mach_task_self_'s own kernel-refcounted-port
        // documentation) that must be deallocated once done with it, or
        // the port's user-reference count leaks by one per call — verified
        // by re-running this call 1000 times and observing the count climb
        // 2 -> 1002 without this line. Bounded (saturates, doesn't crash)
        // but a monitoring pane leaking Mach ports is worth the one line.
        defer { mach_port_deallocate(mach_task_self_, hostPort) }
        let result = host_processor_info(hostPort, PROCESSOR_CPU_LOAD_INFO, &numCpus, &cpuInfo, &numCpuInfo)
        guard result == KERN_SUCCESS, let cpuInfo else { return [] }
        defer {
            vm_deallocate(
                mach_task_self_,
                vm_address_t(bitPattern: cpuInfo),
                vm_size_t(numCpuInfo) * vm_size_t(MemoryLayout<integer_t>.size)
            )
        }

        let stride = Int(CPU_STATE_MAX)
        var cores: [CoreTicks] = []
        cores.reserveCapacity(Int(numCpus))
        for index in 0..<Int(numCpus) {
            let base = index * stride
            // Review round 1 (#0314): `processor_info_array_t` is
            // `integer_t *` — SIGNED Int32. A plain `UInt32(_:)` init traps
            // the moment a counter's bit pattern reads as negative once it
            // passes Int32.max (~250 days of uptime at the reviewer's
            // measured ~99 ticks/s/core) — reproduced directly:
            // `UInt32(Int32(-1))` traps with "Negative value is not
            // representable." `UInt32(bitPattern:)` reinterprets the same
            // 32 bits without the range check, which is exactly what's
            // wanted here — these are wrapping tick counters, not signed
            // quantities, so the bit pattern is the only thing that matters.
            cores.append(
                CoreTicks(
                    user: UInt32(bitPattern: cpuInfo[base + Int(CPU_STATE_USER)]),
                    system: UInt32(bitPattern: cpuInfo[base + Int(CPU_STATE_SYSTEM)]),
                    idle: UInt32(bitPattern: cpuInfo[base + Int(CPU_STATE_IDLE)]),
                    nice: UInt32(bitPattern: cpuInfo[base + Int(CPU_STATE_NICE)])
                )
            )
        }
        return cores
    }

    /// Per-core utilization percentage between two tick snapshots taken at
    /// different times. `nil` if the shapes don't line up (core count
    /// changed — not expected, but a snapshot from a different call should
    /// never be silently zipped against this one).
    public static func percentages(from previous: [CoreTicks], to current: [CoreTicks]) -> [Double]? {
        guard previous.count == current.count, !current.isEmpty else { return nil }
        return zip(previous, current).map { prior, now in
            let totalDelta = now.total >= prior.total ? now.total - prior.total : 0
            guard totalDelta > 0 else { return 0 }
            let busyDelta = now.busy >= prior.busy ? now.busy - prior.busy : 0
            return (Double(busyDelta) / Double(totalDelta)) * 100
        }
    }
}

/// Caller-side previous-tick baseline for `SystemCPUReader`, discarded on
/// hide the same way `ProcessCPUDeltaTracker`'s per-pid map is
/// (`docs/design/system-metrics-view.md` §4).
public nonisolated struct CoreCPUDeltaTracker {
    private var previous: [CoreTicks]?

    public init() {}

    /// Returns `nil` on the first call after creation (no baseline yet) —
    /// the caller renders that as "no percentage yet," never `0%`.
    @discardableResult
    public mutating func percentages(for current: [CoreTicks]) -> [Double]? {
        defer { previous = current }
        guard let previous else { return nil }
        return SystemCPUReader.percentages(from: previous, to: current)
    }

    public mutating func reset() {
        previous = nil
    }
}
