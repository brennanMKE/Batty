// ProcessGroupStopper.swift

import Darwin
import Foundation
import OSLog

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "ProcessGroupStopper")

public nonisolated enum StopTarget: Equatable, Sendable {
    /// Every member of a process group: a server started in a Batty Tab.
    case processGroup(pid_t)
    /// A pid and its descendants: a server started elsewhere, whose own
    /// group may contain its parent shell.
    case processTree(pid_t)
}

public protocol ProcessSignalling: AnyObject {
    /// Returns 0, or the errno of the failed send.
    func signal(_ target: StopTarget, _ sig: Int32) -> Int32
    /// True while any non-zombie process is left in the target.
    func isAlive(_ target: StopTarget) -> Bool
}

public nonisolated enum StopOutcome: Equatable, Sendable {
    /// The target went away after this signal.
    case exited(after: Int32)
    /// Nothing was left to signal before the first signal.
    case alreadyGone
    case killed
    case refused(String)
}

public nonisolated struct StopBounds: Equatable, Sendable {
    public var interrupt: Duration
    public var terminate: Duration
    public var pollInterval: Duration

    public init(interrupt: Duration = .seconds(5), terminate: Duration = .seconds(3), pollInterval: Duration = .milliseconds(250)) {
        self.interrupt = interrupt
        self.terminate = terminate
        self.pollInterval = pollInterval
    }
}

/// Signals a target with SIGINT, then SIGTERM, then SIGKILL, waiting a
/// bounded time on the injected clock between steps.
public enum ProcessGroupStopper {
    /// `check` re-verifies the target right before every signal, so a pid
    /// reused or a group that changed hands mid-escalation is never
    /// signalled. `exitEvent` returns true once the caller learned the job
    /// ended (for example the Tab's command-finished callback), which ends a
    /// wait early.
    public static func stop(
        _ target: StopTarget,
        signaller: ProcessSignalling,
        clock: SchedulingClock,
        bounds: StopBounds = StopBounds(),
        exitEvent: @escaping () -> Bool = { false },
        check: @escaping () -> StopCheck = { .proceed }
    ) async -> StopOutcome {
        if let reason = refusal(for: target) {
            logger.error("stop refused: \(reason, privacy: .public)")
            return .refused(reason)
        }
        var lastSent: Int32?
        for (sig, bound) in [(SIGINT, bounds.interrupt), (SIGTERM, bounds.terminate), (SIGKILL, Duration.zero)] {
            switch check() {
            case .proceed: break
            case .gone: return lastSent.map { .exited(after: $0) } ?? .alreadyGone
            case .refuse(let reason):
                logger.error("stop refused before signal \(sig, privacy: .public): \(reason, privacy: .public)")
                return .refused(reason)
            }
            if Task.isCancelled { return .refused("cancelled") }
            let rc = signaller.signal(target, sig)
            if sig == SIGKILL { return .killed }
            if rc == ESRCH { return .exited(after: sig) }
            lastSent = sig
            if await waitForExit(target, signaller: signaller, clock: clock, bound: bound, poll: bounds.pollInterval, exitEvent: exitEvent) {
                return .exited(after: sig)
            }
            if Task.isCancelled { return .refused("cancelled") }
        }
        return .killed
    }

    /// Targets never signalled whatever the caller's check says: pid or
    /// group 0 and 1, and Batty or any ancestor of Batty, or their groups.
    static func refusal(for target: StopTarget) -> String? {
        let protected = SystemProcessTable.battyAndAncestors()
        switch target {
        case .processGroup(let pgid):
            if pgid <= 1 { return "process group \(pgid) is not a job" }
            if pgid == getpgrp() { return "process group \(pgid) is Batty's own" }
            if protected.contains(where: { getpgid($0) == pgid }) { return "process group \(pgid) belongs to an ancestor of Batty" }
        case .processTree(let pid):
            if pid <= 1 { return "pid \(pid) is not a server" }
            if pid == getpid() { return "pid \(pid) is Batty itself" }
            if protected.contains(pid) { return "pid \(pid) is an ancestor of Batty" }
        }
        return nil
    }

    private static func waitForExit(
        _ target: StopTarget,
        signaller: ProcessSignalling,
        clock: SchedulingClock,
        bound: Duration,
        poll: Duration,
        exitEvent: () -> Bool
    ) async -> Bool {
        var waited: Duration = .zero
        while waited < bound {
            if exitEvent() || !signaller.isAlive(target) { return true }
            if Task.isCancelled { return false }
            await clock.sleep(for: poll)
            waited += poll
        }
        return exitEvent() || !signaller.isAlive(target)
    }
}

/// Production signaller: `killpg` for a group, `kill` over a `pbi_ppid`
/// walk for a tree.
public nonisolated final class SystemProcessSignaller: ProcessSignalling {
    public init() {}

    public func signal(_ target: StopTarget, _ sig: Int32) -> Int32 {
        switch target {
        case .processGroup(let pgid):
            return ProcessSignal.send(sig, toGroup: pgid)
        case .processTree(let root):
            let pids = Self.tree(root: root)
            guard !pids.isEmpty else { return ESRCH }
            var firstError: Int32 = 0
            for pid in pids {
                let rc = ProcessSignal.send(sig, toPid: pid)
                if rc != 0, firstError == 0 { firstError = rc }
            }
            return firstError
        }
    }

    public func isAlive(_ target: StopTarget) -> Bool {
        switch target {
        case .processGroup(let pgid):
            return ListeningPortScanner.processGroupMembers(pgid: pgid).contains { !Self.isZombie($0) }
        case .processTree(let root):
            return Self.tree(root: root).contains { !Self.isZombie($0) }
        }
    }

    static func isZombie(_ pid: pid_t) -> Bool {
        // An unreadable pid (mid-exec, say) counts as dead only if it's gone.
        guard let info = bsdInfo(pid) else { return kill(pid, 0) != 0 }
        return info.pbi_status == UInt32(SZOMB)
    }

    static func bsdInfo(_ pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? info : nil
    }

    /// `root` and every same-user descendant, root first, never Batty or an
    /// ancestor of Batty.
    static func tree(root: pid_t) -> [pid_t] {
        let protected = SystemProcessTable.battyAndAncestors()
        guard !protected.contains(root), bsdInfo(root) != nil else { return [] }
        var parents: [pid_t: [pid_t]] = [:]
        for pid in ListeningPortScanner.sameUserPids() {
            if let info = bsdInfo(pid) { parents[pid_t(info.pbi_ppid), default: []].append(pid) }
        }
        var result: [pid_t] = []
        var queue = [root]
        var seen: Set<pid_t> = []
        while let next = queue.popLast() {
            guard seen.insert(next).inserted, !protected.contains(next) else { continue }
            result.append(next)
            queue.append(contentsOf: parents[next] ?? [])
        }
        return result
    }
}
