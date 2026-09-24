// ProcessMetricsReader.swift

import Darwin
import Foundation
import OSLog

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "ProcessMetricsReader")

/// `proc_listallpids` is called twice — once to size the buffer, once to
/// fill it (`listAllPIDs(failureGate:)` below) — and either call can fail
/// independently, so they're kept as distinct causes (#0353).
public nonisolated enum ProcessListFailure: Equatable, Sendable {
    case probeFailed(count: Int32)
    case fillFailed(count: Int32)
}

/// One process's sampled state — the libproc reads both #0314
/// (whole-system) and #0305 (single selected process) need, factored here
/// per `docs/design/system-metrics-view.md` §5 so whichever view ships
/// first hands the other a ready-made primitive instead of a second copy.
///
/// **Never RSS.** `residentSizeBytes`/`physFootprintBytes` come from
/// `PROC_PIDTASKINFO`/`proc_pid_rusage`, never `ps -o rss`-equivalent
/// figures — `issues/0290.md`'s binding rule, restated at the per-row
/// level `docs/design/system-metrics-view.md` §1.7/§2 apply it at.
///
/// Optional fields are `nil` specifically to mean "this uid can't read
/// that" (a live `EPERM`), never a fabricated zero — a `0` would
/// misrepresent "denied" as "measured," which is exactly the distinction
/// the design's process-list rows are required to preserve.
public nonisolated struct ProcessSample: Sendable, Equatable {
    public let pid: pid_t
    /// Never blank: `proc_name`, falling back to the executable path's
    /// basename, falling back a third time to a hardcoded `"kernel_task"`
    /// label for pid 0 specifically — the one pid where even the path
    /// lookup fails (`docs/design/system-metrics-view.md` §1.7).
    public let name: String
    public let path: String?
    public let threadCount: Int?
    public let physFootprintBytes: UInt64?
    public let residentSizeBytes: UInt64?
    /// Cumulative mach-absolute-time ticks since process start. Caller-side
    /// delta computation (`ProcessCPUDeltaTracker`) turns these into a
    /// CPU% over the sampling interval — kept as raw cumulative ticks here
    /// so a stateless reader stays stateless.
    public let cpuTicksUser: UInt64?
    public let cpuTicksSystem: UInt64?

    public init(
        pid: pid_t,
        name: String,
        path: String?,
        threadCount: Int?,
        physFootprintBytes: UInt64?,
        residentSizeBytes: UInt64?,
        cpuTicksUser: UInt64?,
        cpuTicksSystem: UInt64?
    ) {
        self.pid = pid
        self.name = name
        self.path = path
        self.threadCount = threadCount
        self.physFootprintBytes = physFootprintBytes
        self.residentSizeBytes = residentSizeBytes
        self.cpuTicksUser = cpuTicksUser
        self.cpuTicksSystem = cpuTicksSystem
    }

    /// `true` when the current uid could read neither task info nor
    /// footprint for this pid — the ownership boundary
    /// `docs/design/system-metrics-view.md` §1.7 found spans 213 distinct
    /// root-owned daemons, not a narrow pty-specific case.
    public var isOwnershipDenied: Bool {
        physFootprintBytes == nil && cpuTicksUser == nil
    }
}

/// Reads per-process state via libproc — `proc_pidinfo`, `proc_pid_rusage`,
/// `proc_name`/`proc_pidpath`, `proc_listallpids`. Stateless: every call is
/// an independent snapshot read, no handle held between calls
/// (`docs/design/system-metrics-view.md` §1.1/§1.7, inherited from
/// `docs/design/process-status-view.md` §1.1-§1.3's own per-pid findings).
///
/// `nonisolated` — see `SystemCPUReader`'s doc comment for why every
/// stateless reader in this file group needs this against BattyKit's
/// package-wide default `MainActor` isolation.
public nonisolated enum ProcessMetricsReader {
    /// One pid's current sample, or `nil` if the process no longer exists
    /// (`ESRCH`) — distinguished from a permission denial (`EPERM`), which
    /// returns a sample with `nil` task-info/footprint fields instead.
    public static func sample(pid: pid_t) -> ProcessSample? {
        if pid == 0 {
            // kernel_task: proc_pidinfo/proc_name/proc_pidpath all fail for
            // pid 0 on real hardware even though proc_listallpids returns
            // it (docs/design/system-metrics-view.md §1.7) — a fixed,
            // well-known constant, not something to discover per-machine.
            return ProcessSample(
                pid: 0,
                name: "kernel_task",
                path: nil,
                threadCount: nil,
                physFootprintBytes: nil,
                residentSizeBytes: nil,
                cpuTicksUser: nil,
                cpuTicksSystem: nil
            )
        }

        errno = 0
        let task = readTaskInfo(pid: pid)
        if task == nil, errno == ESRCH {
            return nil
        }

        let footprint = readPhysFootprint(pid: pid)
        let nameResult = readName(pid: pid)
        let pathResult = readPath(pid: pid)

        return ProcessSample(
            pid: pid,
            name: resolvedName(pid: pid, nameResult: nameResult, pathResult: pathResult),
            path: pathResult,
            threadCount: task.map { Int($0.pti_threadnum) },
            physFootprintBytes: footprint,
            residentSizeBytes: task.map { $0.pti_resident_size },
            cpuTicksUser: task.map { $0.pti_total_user },
            cpuTicksSystem: task.map { $0.pti_total_system }
        )
    }

    /// Every pid currently on the machine, sampled once each
    /// (`docs/design/system-metrics-view.md` §1.7: ~2-3ms end to end for
    /// ~800 pids on the spike's Mac mini M4). A pid that exits between
    /// enumeration and sampling is silently dropped rather than
    /// represented as a phantom row.
    public static func sampleAll(failureGate: inout FailureLogGate<ProcessListFailure>) -> [ProcessSample] {
        listAllPIDs(failureGate: &failureGate).compactMap { sample(pid: $0) }
    }

    // MARK: - Enumeration

    /// Review round 1 (#0314), a finding from #0305's own reviewer against
    /// this exact function: `proc_listallpids`'s return value, once a real
    /// buffer is supplied, is a **count of pids already, not a byte
    /// count** — unlike the `buffer == NULL` sizing call (whose header
    /// comment does describe a byte count) and unlike most other libproc
    /// calls in this file. The original version here divided the filled
    /// return by `MemoryLayout<pid_t>.size`, an extra, wrong division that
    /// silently truncated the enumerated list to roughly 1/12th of the
    /// real process count (62 of 716 pids, independently reproduced by the
    /// reviewer and again here before writing this fix — count returned by
    /// the corrected version below matches the actual pid count with pid
    /// 0 and this process's own pid both present). Neither return value
    /// is ever divided by anything now.
    private static func listAllPIDs(failureGate: inout FailureLogGate<ProcessListFailure>) -> [pid_t] {
        let probeCount = proc_listallpids(nil, 0)
        guard probeCount > 0 else {
            logFailure(failureGate.record(failureCode: .probeFailed(count: probeCount)), description: "proc_listallpids probe returned \(probeCount)")
            return []
        }
        // Padded for processes started between the probe and the fill call
        // — a benign, expected race under any concurrent workload.
        var pids = [pid_t](repeating: 0, count: Int(probeCount) + 64)
        let capacityBytes = Int32(pids.count * MemoryLayout<pid_t>.stride)
        let actualCount = proc_listallpids(&pids, capacityBytes)
        guard actualCount > 0 else {
            logFailure(failureGate.record(failureCode: .fillFailed(count: actualCount)), description: "proc_listallpids fill returned \(actualCount)")
            return []
        }
        logFailure(failureGate.record(failureCode: nil), description: "")
        // Unlike a caller that only wants ordinary processes, pid 0 is
        // kept, not filtered — `sample(pid:)`'s hardcoded `"kernel_task"`
        // fallback (`docs/design/system-metrics-view.md` §1.7) depends on
        // pid 0 surviving enumeration.
        return Array(pids.prefix(Int(actualCount)))
    }

    private static func logFailure(_ disposition: FailureLogGate<ProcessListFailure>.Disposition, description: String) {
        switch disposition {
        case .stillOK:
            return
        case .firstFailure, .changedFailure:
            logger.error("process-list: \(description, privacy: .public)")
        case .repeatedFailure:
            logger.debug("process-list: still failing — \(description, privacy: .public)")
        case .recovered:
            logger.info("process-list: recovered")
        }
    }

    // MARK: - Individual reads

    private static func readTaskInfo(pid: pid_t) -> proc_taskinfo? {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(pid, PROC_PIDTASKINFO, 0, $0, size)
        }
        guard result == size else { return nil }
        return info
    }

    private static func readPhysFootprint(pid: pid_t) -> UInt64? {
        var info = rusage_info_current()
        let result = withUnsafeMutablePointer(to: &info) { ptr -> Int32 in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, $0)
            }
        }
        guard result == 0 else { return nil }
        return info.ri_phys_footprint
    }

    private static func readName(pid: pid_t) -> String? {
        var buffer = [UInt8](repeating: 0, count: Int(MAXPATHLEN))
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    private static func readPath(pid: pid_t) -> String? {
        // PROC_PIDPATHINFO_MAXSIZE is unavailable to Swift on current SDKs
        // ("structure not supported") — its own definition, `4 *
        // MAXPATHLEN`, is used directly instead.
        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    private static func resolvedName(pid: pid_t, nameResult: String?, pathResult: String?) -> String {
        if let nameResult, !nameResult.isEmpty { return nameResult }
        if let pathResult, !pathResult.isEmpty {
            return URL(fileURLWithPath: pathResult).lastPathComponent
        }
        return "pid \(pid)"
    }
}
