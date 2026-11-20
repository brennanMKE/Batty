// ServerJobOwnership.swift

import Darwin
import Foundation
import OSLog

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "ServerJobOwnership")

/// A pid plus its kernel start time, so a later process that reuses the pid
/// never matches.
public nonisolated struct ProcessStamp: Hashable, Sendable {
    public var pid: pid_t
    public var startSeconds: UInt64
    public var startMicroseconds: UInt64

    public init(pid: pid_t, startSeconds: UInt64, startMicroseconds: UInt64) {
        self.pid = pid
        self.startSeconds = startSeconds
        self.startMicroseconds = startMicroseconds
    }
}

public nonisolated struct ProcessRecord: Equatable, Sendable {
    public var pid: pid_t
    public var ppid: pid_t
    public var pgid: pid_t
    public var uid: uid_t
    public var startSeconds: UInt64
    public var startMicroseconds: UInt64
    public var isZombie: Bool

    public init(pid: pid_t, ppid: pid_t, pgid: pid_t, uid: uid_t = getuid(), startSeconds: UInt64 = 0, startMicroseconds: UInt64 = 0, isZombie: Bool = false) {
        self.pid = pid
        self.ppid = ppid
        self.pgid = pgid
        self.uid = uid
        self.startSeconds = startSeconds
        self.startMicroseconds = startMicroseconds
        self.isZombie = isZombie
    }

    public var stamp: ProcessStamp {
        ProcessStamp(pid: pid, startSeconds: startSeconds, startMicroseconds: startMicroseconds)
    }
}

/// One read of the whole process table.
public nonisolated struct ProcessSnapshot: Sendable {
    public var records: [pid_t: ProcessRecord]

    public init(_ records: [ProcessRecord]) {
        self.records = Dictionary(records.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// `pid`'s parent, grandparent and so on, nearest first, ending before
    /// pid 0.
    public func ancestors(of pid: pid_t) -> [pid_t] {
        var result: [pid_t] = []
        var seen: Set<pid_t> = [pid]
        var current = records[pid]?.ppid ?? 0
        while current > 0, seen.insert(current).inserted {
            result.append(current)
            current = records[current]?.ppid ?? 0
        }
        return result
    }

    public func descends(_ pid: pid_t, from ancestor: pid_t) -> Bool {
        ancestors(of: pid).contains(ancestor)
    }

    /// Live (non-zombie) members of process group `pgid`.
    public func liveMembers(ofGroup pgid: pid_t) -> [ProcessRecord] {
        records.values.filter { $0.pgid == pgid && !$0.isZombie }
    }
}

/// Reads the process table, and a process's environment, so tests can supply
/// a fake one.
public nonisolated protocol ProcessTableReading: AnyObject, Sendable {
    /// Batty's own pid.
    var selfPid: pid_t { get }
    func snapshot() -> ProcessSnapshot
    /// The environment strings (`NAME=value`) of a same-user process, or nil
    /// when it can't be read.
    func environment(of pid: pid_t) -> [String]?
}

/// The moment before a server's terminal Tab was created, so its shell
/// can be told apart from shells that already existed.
public nonisolated struct ShellSpawnBaseline: Equatable, Sendable {
    public var seconds: UInt64
    public var microseconds: UInt64

    public init(seconds: UInt64, microseconds: UInt64) {
        self.seconds = seconds
        self.microseconds = microseconds
    }

    /// The process table's clock (`p_starttime` is wall-clock time).
    public static func now() -> ShellSpawnBaseline {
        var time = timeval()
        gettimeofday(&time, nil)
        return ShellSpawnBaseline(seconds: UInt64(max(0, time.tv_sec)), microseconds: UInt64(max(0, Int64(time.tv_usec))))
    }

    func precedes(_ record: ProcessRecord) -> Bool {
        (seconds, microseconds) <= (record.startSeconds, record.startMicroseconds)
    }
}

public nonisolated enum StopCheck: Equatable, Sendable {
    case proceed
    /// Nothing is left to signal.
    case gone
    case refuse(String)
}

/// What Stop signals, and the identities it re-checks before each signal.
public nonisolated struct StopPlan: Equatable, Sendable {
    public var target: StopTarget
    /// For a group: the Tab's shell, which every member must descend from.
    public var shell: ProcessStamp?
    /// The group leader (group) or the root (tree), as found when planned.
    /// Nil when a group's leader had already exited.
    public var anchor: ProcessStamp?

    public init(target: StopTarget, shell: ProcessStamp? = nil, anchor: ProcessStamp?) {
        self.target = target
        self.shell = shell
        self.anchor = anchor
    }
}

public nonisolated enum ServerStopDecision: Equatable, Sendable {
    /// No listener, so nothing to signal.
    case nothing
    case signal(StopPlan)
    case refused(String)
}

/// Decides which processes a server's Stop may signal. A started server
/// is a job of the Pane's own Tab: its group must differ from the Tab shell's
/// and every member must descend from that shell. An attached server is the
/// listener and its descendants. Neither may include Batty or any ancestor
/// of Batty.
public nonisolated enum ServerJobResolver {
    public static func tabEnvironmentEntry(_ tabID: UUID) -> String {
        "BATTY_TAB_ID=\(tabID.uuidString)"
    }

    /// The shell Batty spawned for `tabID`. Tab shells are Batty's
    /// same-user children, or the same-user children of Batty's root-owned
    /// `login` children. A shell whose environment is readable is matched by
    /// the Tab's `BATTY_TAB_ID`. The kernel hides the environment of platform
    /// binaries such as `/bin/zsh`, so otherwise the shell must be the only
    /// one whose Batty child started after `baseline`, the moment before the
    /// Tab was created. Anything ambiguous is nil, so Stop refuses.
    public static func locateTabShell(tabID: UUID, spawnedAfter baseline: ShellSpawnBaseline?, snapshot: ProcessSnapshot, table: ProcessTableReading) -> ProcessRecord? {
        let selfPid = table.selfPid
        let uid = getuid()
        let entry = tabEnvironmentEntry(tabID)
        var shells: [(shell: ProcessRecord, battyChild: ProcessRecord)] = []
        for child in snapshot.records.values where child.ppid == selfPid && !child.isZombie {
            if child.uid == uid {
                shells.append((child, child))
            } else {
                for grandchild in snapshot.records.values where grandchild.ppid == child.pid && grandchild.uid == uid && !grandchild.isZombie {
                    shells.append((grandchild, child))
                }
            }
        }
        var unknown: [(shell: ProcessRecord, battyChild: ProcessRecord)] = []
        for candidate in shells.sorted(by: { $0.shell.pid < $1.shell.pid }) {
            let environment = table.environment(of: candidate.shell.pid) ?? []
            if environment.contains(entry) { return candidate.shell }
            if environment.isEmpty { unknown.append(candidate) }
        }
        guard let baseline else { return nil }
        let fresh = unknown.filter { baseline.precedes($0.battyChild) }
        return fresh.count == 1 ? fresh[0].shell : nil
    }

    /// Batty and every ancestor of Batty.
    static func protectedPids(selfPid: pid_t, snapshot: ProcessSnapshot) -> Set<pid_t> {
        Set([selfPid] + snapshot.ancestors(of: selfPid))
    }

    /// The groups of Batty and its ancestors, plus 0 and 1.
    static func protectedGroups(selfPid: pid_t, snapshot: ProcessSnapshot) -> Set<pid_t> {
        var groups: Set<pid_t> = [0, 1]
        for pid in protectedPids(selfPid: selfPid, snapshot: snapshot) {
            if let pgid = snapshot.records[pid]?.pgid { groups.insert(pgid) }
        }
        if selfPid == getpid() { groups.insert(getpgrp()) }
        return groups
    }

    public static func planGroupStop(listener: pid_t, shell: ProcessRecord, snapshot: ProcessSnapshot, selfPid: pid_t) -> ServerStopDecision {
        guard let record = snapshot.records[listener], !record.isZombie else { return .nothing }
        guard snapshot.descends(listener, from: shell.pid) else {
            return .refused("pid \(listener) was not started from this server's terminal")
        }
        let leader = snapshot.records[record.pgid].flatMap { $0.isZombie ? nil : $0.stamp }
        let plan = StopPlan(target: .processGroup(record.pgid), shell: shell.stamp, anchor: leader)
        switch check(plan, snapshot: snapshot, selfPid: selfPid) {
        case .proceed: return .signal(plan)
        case .gone: return .nothing
        case .refuse(let reason): return .refused(reason)
        }
    }

    public static func planTreeStop(listener: pid_t, snapshot: ProcessSnapshot, selfPid: pid_t) -> ServerStopDecision {
        guard let record = snapshot.records[listener], !record.isZombie else { return .nothing }
        let plan = StopPlan(target: .processTree(listener), anchor: record.stamp)
        switch check(plan, snapshot: snapshot, selfPid: selfPid) {
        case .proceed: return .signal(plan)
        case .gone: return .nothing
        case .refuse(let reason): return .refused(reason)
        }
    }

    /// Re-verifies `plan` against a fresh snapshot, right before a signal.
    public static func check(_ plan: StopPlan, snapshot: ProcessSnapshot, selfPid: pid_t) -> StopCheck {
        let protected = protectedPids(selfPid: selfPid, snapshot: snapshot)
        switch plan.target {
        case .processGroup(let pgid):
            if protectedGroups(selfPid: selfPid, snapshot: snapshot).contains(pgid) {
                return .refuse("process group \(pgid) belongs to Batty or one of its ancestors")
            }
            guard let shellStamp = plan.shell else { return .refuse("no Tab shell recorded for process group \(pgid)") }
            guard let shell = snapshot.records[shellStamp.pid], shell.stamp == shellStamp, !shell.isZombie else {
                return .refuse("the terminal's shell has exited")
            }
            if pgid == shell.pgid { return .refuse("process group \(pgid) is the terminal shell's own") }
            let members = snapshot.liveMembers(ofGroup: pgid)
            if members.isEmpty { return .gone }
            if let anchor = plan.anchor, let leader = snapshot.records[anchor.pid], leader.pgid == pgid, leader.stamp != anchor {
                return .refuse("pid \(anchor.pid) was reused by another process")
            }
            for member in members {
                if protected.contains(member.pid) { return .refuse("pid \(member.pid) is Batty or one of its ancestors") }
                if !snapshot.descends(member.pid, from: shell.pid) {
                    return .refuse("process group \(pgid) holds pid \(member.pid), which was not started from this server's terminal")
                }
            }
            return .proceed
        case .processTree(let root):
            if root <= 1 || protected.contains(root) { return .refuse("pid \(root) is Batty or one of its ancestors") }
            guard let record = snapshot.records[root], !record.isZombie else { return .gone }
            if let anchor = plan.anchor, record.stamp != anchor { return .refuse("pid \(root) was reused by another process") }
            return .proceed
        }
    }
}

/// The live process table, read with `sysctl(KERN_PROC_ALL)`, which covers
/// other users' processes too (Batty's `login` parent of each shell is
/// root's).
public nonisolated final class SystemProcessTable: ProcessTableReading {
    public init() {}

    public var selfPid: pid_t { getpid() }

    public func snapshot() -> ProcessSnapshot {
        ProcessSnapshot(Self.allRecords())
    }

    public func environment(of pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        return Self.environment(fromProcArgs2: Array(buffer.prefix(size)))
    }

    /// The environment block of a `KERN_PROCARGS2` buffer: after argc, the
    /// exec path (NUL-padded to 8-byte alignment from offset 4) and argc
    /// argv strings, up to the first empty string.
    static func environment(fromProcArgs2 buffer: [UInt8]) -> [String] {
        guard buffer.count > 4 else { return [] }
        let argc: Int32 = buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: Int32.self) }
        var offset = 4
        while offset < buffer.count, buffer[offset] != 0 { offset += 1 }
        offset += 1
        while offset < buffer.count, (offset - 4) % 8 != 0, buffer[offset] == 0 { offset += 1 }
        var remaining = argc
        while offset < buffer.count, remaining > 0 {
            if buffer[offset] == 0 { remaining -= 1 }
            offset += 1
        }
        var environment: [String] = []
        var current: [UInt8] = []
        while offset < buffer.count {
            let byte = buffer[offset]
            offset += 1
            if byte != 0 {
                current.append(byte)
            } else if current.isEmpty {
                break
            } else {
                environment.append(String(decoding: current, as: UTF8.self))
                current = []
            }
        }
        return environment
    }

    static func allRecords() -> [ProcessRecord] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        for _ in 0..<5 {
            var size = 0
            guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { break }
            let stride = MemoryLayout<kinfo_proc>.stride
            var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 32)
            size = procs.count * stride
            if sysctl(&mib, 4, &procs, &size, nil, 0) != 0 {
                if errno == ENOMEM { continue }
                break
            }
            return procs.prefix(size / stride).map(record)
        }
        logger.error("KERN_PROC_ALL failed: errno \(errno, privacy: .public)")
        return []
    }

    /// One process, or nil when it is gone.
    static func record(pid: pid_t) -> ProcessRecord? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size == MemoryLayout<kinfo_proc>.stride else { return nil }
        return record(info)
    }

    private static func record(_ info: kinfo_proc) -> ProcessRecord {
        let start = info.kp_proc.p_un.__p_starttime
        return ProcessRecord(
            pid: info.kp_proc.p_pid,
            ppid: info.kp_eproc.e_ppid,
            pgid: info.kp_eproc.e_pgid,
            uid: info.kp_eproc.e_pcred.p_ruid,
            startSeconds: UInt64(max(0, start.tv_sec)),
            startMicroseconds: UInt64(max(0, Int64(start.tv_usec))),
            isZombie: info.kp_proc.p_stat == CChar(SZOMB)
        )
    }

    /// Batty and each of its ancestors, read hop by hop.
    static func battyAndAncestors() -> Set<pid_t> {
        var result: Set<pid_t> = [getpid()]
        var current = getppid()
        while current > 0, result.insert(current).inserted {
            current = record(pid: current)?.ppid ?? 0
        }
        return result
    }
}
