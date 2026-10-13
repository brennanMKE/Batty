// ProcessInspector.swift

import Darwin
import Foundation

/// Thin wrapper over the libproc/sysctl calls `#0305`'s phase-1 spike
/// proved obtainable for a same-uid process without a Mach task port
/// (`task_for_pid` fails for every target tested, same-uid or root, on
/// this OS — `docs/design/process-status-view.md` §1). Every call here is
/// synchronous and sub-millisecond, so it is safe to call directly from a
/// 1-second polling `Task` with no dispatch-queue hop and no subprocess.
///
/// Candidate for consolidation with `#0314`'s whole-system sampler: both
/// need `proc_listallpids`-based enumeration and per-pid `proc_pidinfo`
/// reads. The per-pid functions here (`coreMetrics`, `identity`,
/// `commandLine`) are the reusable per-process unit; `allSameUserProcesses`
/// and `children(ofPid:)` are the whole-system-enumeration unit `#0314`
/// most likely needs its own copy or a shared version of.
public enum ProcessInspector {
    /// Why a sample failed, keyed off the kernel's own distinguishable
    /// error codes rather than inferred (`docs/design/process-status-view.md`
    /// §1.4): `ESRCH` means the pid no longer exists (exited, or never
    /// existed); `EPERM` means it exists but this process cannot read it
    /// (a different-uid target).
    public enum SampleFailure: Error, Equatable, Sendable {
        case processNotFound
        case permissionDenied
        case unexpected(errno: Int32)

        init(errno code: Int32) {
            switch code {
            case ESRCH: self = .processNotFound
            case EPERM: self = .permissionDenied
            default: self = .unexpected(errno: code)
            }
        }
    }

    /// Always-sampled, every tick (§1.7/§3.2 of the design doc) — bounded
    /// strictly to what the spike proved cheap and obtainable.
    public struct CoreMetrics: Equatable, Sendable {
        public var residentBytes: UInt64
        public var physFootprintBytes: UInt64
        public var threadCount: Int
        /// `nil` when the fd-count read itself failed (`EPERM`/`ESRCH`) —
        /// distinct from a real zero, which is a legitimate count
        /// (review round 1, S1: a failed read must never render as a
        /// plausible measured `0`, the same discipline `#0290`'s
        /// `FootprintReader` already applies to its own metric).
        public var openFileCount: Int?
        /// Cumulative CPU time, in **raw mach-absolute-time ticks** —
        /// `rusage_info_v4.ri_user_time`/`ri_system_time` report ticks,
        /// not nanoseconds, despite the field names (`#0314`'s
        /// `MachTimebase`/`ProcessCPUDeltaTracker.swift` has the full
        /// story: review round 1 found #0305's own first attempt at this
        /// conversion under-reported CPU% by ~42x). Kept as raw ticks
        /// here, unconverted, specifically so this type can feed
        /// `ProcessCPUDeltaTracker` directly — the shared component both
        /// this view and `#0314`'s whole-system one delta against a prior
        /// sample and convert to nanoseconds internally, rather than each
        /// view converting once on read and delta-ing already-converted
        /// values (harmless numerically, but two copies of the
        /// conversion is exactly the duplication `#0314` was adopted to
        /// remove). A monotonically growing total is not "CPU usage" on
        /// its own — the caller deltas two samples across a known
        /// wall-clock interval (design §3.2's "delta-computed, not
        /// cumulative").
        public var cpuTicksUser: UInt64
        public var cpuTicksSystem: UInt64
    }

    /// `PROC_PIDTASKINFO` (thread count, resident size) plus
    /// `proc_pid_rusage`/`RUSAGE_INFO_V4` (`phys_footprint`, cumulative
    /// CPU time as raw mach ticks — conversion is the caller's job via
    /// the shared `ProcessCPUDeltaTracker`) plus a cheap open-file-
    /// descriptor *count* (`openFileDescriptorCount`,
    /// which does not resolve any vnode path — review round 1, S5: this
    /// call runs every tick, so it must stay O(1)-ish against the fd
    /// table, not O(fd count) with a `proc_pidfdinfo` call per vnode fd).
    /// The full path-resolving listing is `listOpenFileDescriptors`,
    /// on-demand only.
    public static func coreMetrics(pid: pid_t) -> Result<CoreMetrics, SampleFailure> {
        var taskInfo = proc_taskinfo()
        let taskInfoSize = Int32(MemoryLayout<proc_taskinfo>.stride)
        errno = 0
        let taskRC = withUnsafeMutablePointer(to: &taskInfo) {
            proc_pidinfo(pid, PROC_PIDTASKINFO, 0, $0, taskInfoSize)
        }
        guard taskRC == taskInfoSize else {
            return .failure(SampleFailure(errno: errno))
        }

        var usage = rusage_info_v4()
        errno = 0
        let rusageRC = withUnsafeMutablePointer(to: &usage) { pointer -> Int32 in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(pid, RUSAGE_INFO_V4, rebound)
            }
        }
        guard rusageRC == 0 else {
            return .failure(SampleFailure(errno: errno))
        }

        return .success(CoreMetrics(
            residentBytes: usage.ri_resident_size,
            physFootprintBytes: usage.ri_phys_footprint,
            threadCount: Int(taskInfo.pti_threadnum),
            openFileCount: openFileDescriptorCount(pid: pid),
            cpuTicksUser: usage.ri_user_time,
            cpuTicksSystem: usage.ri_system_time
        ))
    }

    public struct Identity: Equatable, Sendable {
        public var name: String?
        public var executablePath: String?
    }

    /// Never fails outright — §1.6's "bonus finding" is that identity data
    /// sits behind a looser permission tier than metrics data (`proc_pidpath`
    /// succeeded for root's `launchd` when every metrics call against the
    /// same pid returned `EPERM`; `proc_name` did not). So this returns
    /// whatever succeeded rather than an all-or-nothing result — a caller
    /// can get an executable path with no name, which is exactly the
    /// permission-denied header state needs.
    public static func identity(pid: pid_t) -> Identity {
        var pathBuffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        errno = 0
        let pathLength = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        let path = pathLength > 0 ? String(decoding: pathBuffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self) : nil

        var nameBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        errno = 0
        let nameLength = proc_name(pid, &nameBuffer, UInt32(nameBuffer.count))
        let name = nameLength > 0 ? String(decoding: nameBuffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self) : nil

        return Identity(name: name, executablePath: path)
    }

    /// Full argv via `sysctl(KERN_PROCARGS2)` (§1.6). Same-uid only —
    /// fails `EINVAL` for a different-uid target, the same permission
    /// boundary as the metrics calls, so this never returns a partial or
    /// guessed command line for a process this feature can't fully read.
    public static func commandLine(pid: pid_t) -> Result<String, SampleFailure> {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        errno = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else {
            return .failure(SampleFailure(errno: errno))
        }
        var buffer = [UInt8](repeating: 0, count: size)
        errno = 0
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else {
            return .failure(SampleFailure(errno: errno))
        }
        return .success(Self.parseProcArgs2(buffer))
    }

    /// `KERN_PROCARGS2`'s layout: a 4-byte argc, then the saved exec path
    /// (NUL-terminated, then NUL-padded to alignment), then `argc`
    /// NUL-terminated strings — the real argv, whose first element is
    /// usually a copy of the exec path. Returns argv joined with spaces:
    /// the design's own use (§3.3, a single copyable command-line string)
    /// doesn't need a structured argv.
    ///
    /// **Every argv terminator must be counted, including a zero-length
    /// argument's** (review round 1, F1 — a real security-adjacent bug,
    /// not just a correctness nit). The previous version only decremented
    /// `remaining` when `current` was non-empty, so a process invoked
    /// with an empty argv element (e.g. `cmd ""`) never reached `argc`
    /// terminators and the loop kept consuming bytes past the end of
    /// argv — straight into the environment block that follows it in this
    /// same buffer, appending environment strings (potentially secrets)
    /// onto what's displayed and offered as "Copy Command Line."
    ///
    /// **Round 2: that fix alone was incomplete for a zero-length
    /// `argv[0]` specifically.** The old padding-skip loop
    /// (`while buffer[offset] == 0 { offset += 1 }`) consumed *every*
    /// consecutive NUL after the exec path, so a genuinely empty
    /// `argv[0]`'s own terminator was indistinguishable from padding and
    /// got eaten — the parser then read `argc` terminators starting at
    /// `argv[1]`, overran argv by one, and appended the first
    /// environment string, unnoticed by hand-built fixtures because both
    /// of them placed their zero-length argument at index ≥ 1. Fixed
    /// using the kernel's own layout rule, measured directly against live
    /// `KERN_PROCARGS2` buffers across ten exec-path lengths: argv always
    /// begins at the first offset satisfying `(offset - 4) % 8 == 0` —
    /// 8-byte alignment relative to the exec-path region starting at
    /// offset 4 — and padding never crosses that boundary. So the exec
    /// path's own terminator is consumed unconditionally (never treated
    /// as swallowable padding), and only *additional* NULs short of that
    /// alignment boundary are skipped as padding; a NUL sitting exactly
    /// at the aligned offset is always a real, empty `argv[0]`, not
    /// padding, and is preserved for the main loop below to consume as
    /// its first terminator.
    // `internal` (not `private`) deliberately — `ProcessInspectorTests`
    // constructs synthetic and kernel-derived KERN_PROCARGS2-shaped
    // buffers to pin this parser's argv/environment boundary directly
    // (review round 1/2, F1), rather than only exercising it indirectly
    // through a live `sysctl` call.
    static func parseProcArgs2(_ buffer: [UInt8]) -> String {
        guard buffer.count > 4 else { return "" }
        let argc: Int32 = buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: Int32.self) }
        var offset = 4
        while offset < buffer.count, buffer[offset] != 0 { offset += 1 } // the saved exec path
        offset += 1 // its own NUL terminator — never swallowable padding
        while offset < buffer.count, (offset - 4) % 8 != 0, buffer[offset] == 0 { offset += 1 } // padding only, short of the 8-byte-aligned argv start

        var args: [String] = []
        var current: [UInt8] = []
        var remaining = argc
        while offset < buffer.count, remaining > 0 {
            let byte = buffer[offset]
            offset += 1
            if byte == 0 {
                args.append(String(decoding: current, as: UTF8.self))
                current = []
                remaining -= 1
            } else {
                current.append(byte)
            }
        }
        return args.joined(separator: " ")
    }

    public struct OpenFileDescriptor: Identifiable, Equatable, Sendable {
        public var id: Int32
        public var isVnode: Bool
        public var path: String?
    }

    /// On-demand only (§1.7/§3.4) — O(fd count), not O(1) against the
    /// target pid (every vnode fd costs one additional `proc_pidfdinfo`
    /// call to resolve its path), so callers must not call this every
    /// refresh tick — use `openFileDescriptorCount` for the per-tick
    /// count instead. `nil` on failure (`EPERM`/`ESRCH`); an empty array
    /// is a real "no open files" result, distinguished deliberately.
    public static func listOpenFileDescriptors(pid: pid_t) -> [OpenFileDescriptor]? {
        guard let descriptors = fetchFileDescriptors(pid: pid) else { return nil }

        return descriptors.map { entry in
            guard entry.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) else {
                return OpenFileDescriptor(id: entry.proc_fd, isVnode: false, path: nil)
            }
            var vnodeInfo = vnode_fdinfowithpath()
            let vnodeSize = Int32(MemoryLayout<vnode_fdinfowithpath>.stride)
            errno = 0
            let vnodeRC = withUnsafeMutablePointer(to: &vnodeInfo) {
                proc_pidfdinfo(pid, entry.proc_fd, PROC_PIDFDVNODEPATHINFO, $0, vnodeSize)
            }
            guard vnodeRC == vnodeSize else {
                return OpenFileDescriptor(id: entry.proc_fd, isVnode: true, path: nil)
            }
            let path = withUnsafeBytes(of: vnodeInfo.pvip.vip_path) { raw -> String in
                String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
            }
            return OpenFileDescriptor(id: entry.proc_fd, isVnode: true, path: path)
        }
    }

    /// The cheap, per-tick-safe half of `listOpenFileDescriptors` — the
    /// count alone, with no `PROC_PIDFDVNODEPATHINFO` calls (review round
    /// 1, S5). `nil` on failure, matching `CoreMetrics.openFileCount`'s
    /// own nil-on-failure contract (S1).
    public static func openFileDescriptorCount(pid: pid_t) -> Int? {
        fetchFileDescriptors(pid: pid)?.count
    }

    /// Shared fetch behind both of the above. `PROC_PIDLISTFDS`'s own
    /// zero-buffer "how big does the buffer need to be" probe reports the
    /// fd *table capacity*, not the count of descriptors actually open
    /// (re-verified against a live process while implementing #0305 —
    /// the probe's answer and a real fetch's returned byte count
    /// disagreed by more than 10x for the same process at the same
    /// instant) — but it is still a valid, safe *upper bound* to size an
    /// allocation from (review round 1, S2: a hardcoded 4096-entry cap
    /// silently truncated a process with more descriptors than that). This
    /// allocates from the probe (plus slack) and, on the rare chance the
    /// real fetch exactly fills that buffer (meaning there may be more),
    /// doubles and retries, up to a generous absolute ceiling.
    private static func fetchFileDescriptors(pid: pid_t) -> [proc_fdinfo]? {
        errno = 0
        let probeBytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        var capacity = probeBytes > 0
            ? Int(probeBytes) / MemoryLayout<proc_fdinfo>.stride + 64
            : 1024
        let maximumCapacity = 1 << 20 // 1,048,576 descriptors — far beyond any real getrlimit(NOFILE).

        while true {
            var descriptors = [proc_fdinfo](repeating: proc_fdinfo(proc_fd: 0, proc_fdtype: 0), count: capacity)
            let bufferSize = Int32(capacity * MemoryLayout<proc_fdinfo>.stride)
            errno = 0
            let rc = descriptors.withUnsafeMutableBufferPointer { buffer -> Int32 in
                proc_pidinfo(pid, PROC_PIDLISTFDS, 0, buffer.baseAddress, bufferSize)
            }
            guard rc >= 0 else { return nil }
            if rc == 0 {
                // `proc_pidinfo` also returns 0 on outright failure
                // (EPERM/ESRCH) — distinguish "genuinely zero fds" from
                // "call failed" via errno, cleared immediately before this
                // call so a stale value from something else can't leak in.
                return errno == 0 ? [] : nil
            }
            if rc == bufferSize, capacity < maximumCapacity {
                capacity *= 2
                continue
            }
            let count = Int(rc) / MemoryLayout<proc_fdinfo>.stride
            return Array(descriptors.prefix(count))
        }
    }

    public struct ChildProcess: Identifiable, Equatable, Sendable {
        public var id: pid_t
        public var name: String
    }

    /// O(system process count), not O(target's children) — there is no
    /// direct "list children of pid X" libproc call (§1.3), so this
    /// enumerates every pid on the system and filters by `pbi_ppid`.
    /// On-demand only, for the same reason as `listOpenFileDescriptors`.
    public static func children(ofPid targetPid: pid_t) -> [ChildProcess] {
        allPids().compactMap { pid -> ChildProcess? in
            guard let info = bsdInfo(pid: pid), info.pbi_ppid == UInt32(targetPid) else { return nil }
            return ChildProcess(id: pid, name: bsdName(info))
        }
    }

    public struct RunningProcess: Identifiable, Equatable, Sendable {
        public var id: pid_t
        public var name: String
        public var executablePath: String?
        /// `proc_bsdinfo.pbi_start_tvsec`/`pbi_start_tvusec`, the process's
        /// kernel start time. Only used to order same-named processes.
        public var startSeconds: UInt64
        public var startMicroseconds: UInt64

        public init(
            id: pid_t,
            name: String,
            executablePath: String? = nil,
            startSeconds: UInt64 = 0,
            startMicroseconds: UInt64 = 0
        ) {
            self.id = id
            self.name = name
            self.executablePath = executablePath
            self.startSeconds = startSeconds
            self.startMicroseconds = startMicroseconds
        }

        /// The one ordering the picker list and follow-by-name resolution
        /// share: name ascending (localized, case-insensitive), then start
        /// time ascending, then pid ascending.
        public static func listOrder(_ lhs: RunningProcess, _ rhs: RunningProcess) -> Bool {
            switch lhs.name.localizedCaseInsensitiveCompare(rhs.name) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: break
            }
            if lhs.startSeconds != rhs.startSeconds { return lhs.startSeconds < rhs.startSeconds }
            if lhs.startMicroseconds != rhs.startMicroseconds { return lhs.startMicroseconds < rhs.startMicroseconds }
            return lhs.id < rhs.id
        }
    }

    /// Same-uid processes only (§2's "Pick a Running Process…" picker) —
    /// there is nothing else this feature can usefully show metrics for
    /// (§1.5). Whole-system enumeration, affordable once per picker open
    /// (§1.3's ~1ms for the full pid list), never per refresh tick —
    /// callers must fetch this from an explicit user action, never from a
    /// `body`/computed-property path that re-evaluates on every tick
    /// (review round 1, S4).
    public static func allSameUserProcesses() -> [RunningProcess] {
        let myUID = getuid()
        return allPids().compactMap { pid -> RunningProcess? in
            guard let info = bsdInfo(pid: pid), info.pbi_uid == myUID else { return nil }
            let path = identity(pid: pid).executablePath
            return RunningProcess(
                id: pid,
                name: bsdName(info),
                executablePath: path,
                startSeconds: info.pbi_start_tvsec,
                startMicroseconds: info.pbi_start_tvusec
            )
        }
    }

    /// The first same-uid process whose `bsdName` equals `name` exactly
    /// (case-sensitive) under ``RunningProcess/listOrder(_:_:)``, i.e. the
    /// longest-running one, then the lowest pid. Walks `allPids()` +
    /// `bsdInfo` only (no `proc_pidpath` per pid), since follow-by-name
    /// calls this once per tick while no match is held.
    public static func firstSameUserProcess(named name: String) -> pid_t? {
        let myUID = getuid()
        var best: RunningProcess?
        for pid in allPids() {
            guard let info = bsdInfo(pid: pid), info.pbi_uid == myUID, bsdName(info) == name else { continue }
            let candidate = RunningProcess(
                id: pid,
                name: name,
                startSeconds: info.pbi_start_tvsec,
                startMicroseconds: info.pbi_start_tvusec
            )
            if let current = best, !RunningProcess.listOrder(candidate, current) { continue }
            best = candidate
        }
        return best?.id
    }

    /// The name the enumerator would list `pid` under, or `nil` when the
    /// pid is gone or unreadable.
    public static func listedName(pid: pid_t) -> String? {
        bsdInfo(pid: pid).map(bsdName)
    }

    // MARK: - Shared low-level helpers

    private static func allPids() -> [pid_t] {
        errno = 0
        let probeCount = proc_listallpids(nil, 0)
        guard probeCount > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(probeCount) + 64)
        let capacityBytes = Int32(pids.count * MemoryLayout<pid_t>.stride)
        // `proc_listallpids`'s return value is a *count of pids*, not a
        // byte count — unlike `proc_pidinfo`'s flavors. Re-verified while
        // implementing this: dividing by `MemoryLayout<pid_t>.stride` here
        // (the natural-looking mistake, matching every other call in this
        // file) silently truncated the list to roughly a quarter of its
        // real size.
        errno = 0
        let actualCount = proc_listallpids(&pids, capacityBytes)
        guard actualCount > 0 else { return [] }
        // Round 2: keeps pid 0 (`kernel_task`), matching `#0314`'s
        // `ProcessMetricsReader.listAllPIDs()` exactly, rather than
        // filtering it out here — confirmed lossless for all callers of
        // this function (`children(ofPid:)`/`allSameUserProcesses()`/
        // `firstSameUserProcess(named:)`):
        // pid 0 is root-owned with ppid 0, so `bsdInfo(pid: 0)` fails
        // (matching `ProcessMetricsReader`'s own doc comment that
        // `proc_pidinfo` fails for pid 0 on real hardware) and it never
        // matches either call site's filter anyway.
        return Array(pids.prefix(Int(actualCount)))
    }

    private static func bsdInfo(pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        errno = 0
        let rc = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, $0, size)
        }
        return rc == size ? info : nil
    }

    private static func bsdName(_ info: proc_bsdinfo) -> String {
        withUnsafeBytes(of: info.pbi_name) { raw -> String in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
    }
}
