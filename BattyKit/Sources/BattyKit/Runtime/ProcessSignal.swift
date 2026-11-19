// ProcessSignal.swift

import Darwin
import Foundation
import os

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "ProcessSignal")

/// The one place BattyKit sends a real signal. Every send returns 0 or an
/// errno. `kill(pid, 0)` liveness probes are not signals and don't come here.
///
/// Hard refusals, in production too, return `EINVAL` without sending: a pid
/// of 0 or less, a group of 1 or less, and Batty's own group.
nonisolated enum ProcessSignal {
    enum Target: Equatable, Sendable {
        case pid(pid_t)
        case group(pid_t)
    }

    /// Test-only hook, consulted after the hard refusals and before the real
    /// send. Returning `false` refuses the send with `EPERM`. Nil in
    /// production: nothing under `Sources/` sets it.
    static var audit: (@Sendable (Target, Int32) -> Bool)? {
        get { auditLock.withLock { auditHook } }
        set { auditLock.withLock { auditHook = newValue } }
    }

    private static let auditLock = NSLock()
    nonisolated(unsafe) private static var auditHook: (@Sendable (Target, Int32) -> Bool)?

    static func refusal(for target: Target) -> String? {
        switch target {
        case .pid(let pid):
            if pid <= 0 { return "pid \(pid) names a group, not a process" }
        case .group(let pgid):
            if pgid <= 1 { return "process group \(pgid) is not a job" }
            if pgid == getpgrp() { return "process group \(pgid) is our own" }
        }
        return nil
    }

    @discardableResult
    static func send(_ sig: Int32, toPid pid: pid_t) -> Int32 {
        deliver(sig, to: .pid(pid))
    }

    @discardableResult
    static func send(_ sig: Int32, toGroup pgid: pid_t) -> Int32 {
        deliver(sig, to: .group(pgid))
    }

    /// Sends only while `process` is running and its pid's parent is still
    /// us, so a pid Foundation has already reaped (and the kernel may have
    /// reused for someone else's process) is never signalled. The one
    /// remaining window is the pid being reused by another of our own
    /// children between the check and the send, which needs a full pid wrap.
    @discardableResult
    static func send(_ sig: Int32, to process: Process) -> Int32 {
        guard process.isRunning else { return ESRCH }
        let pid = process.processIdentifier
        guard parent(of: pid) == getpid() else { return ESRCH }
        return deliver(sig, to: .pid(pid))
    }

    static func parent(of pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return pid_t(info.pbi_ppid)
    }

    private static func deliver(_ sig: Int32, to target: Target) -> Int32 {
        if let reason = refusal(for: target) {
            logger.error("signal \(sig, privacy: .public) refused: \(reason, privacy: .public)")
            return EINVAL
        }
        if let audit, !audit(target, sig) {
            return EPERM
        }
        let rc: Int32
        switch target {
        case .pid(let pid): rc = kill(pid, sig)
        case .group(let pgid): rc = killpg(pgid, sig)
        }
        return rc == 0 ? 0 : errno
    }
}
