// ListeningPortScanner.swift

import Darwin
import Foundation
import OSLog

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "ListeningPortScanner")

/// Finds which processes hold a TCP socket in `LISTEN` on a port, with
/// libproc only (no `lsof`). Nonisolated, unlike `ProcessInspector` (which
/// inherits the package's main-actor default), so a whole-table scan can run
/// off the main actor.
public nonisolated enum ListeningPortScanner {
    /// The pids among `candidates` with a listening TCP socket on `port`.
    /// A pid that can't be read (another user's, or gone) is skipped.
    public static func listeners(port: UInt16, among candidates: [pid_t]) -> [pid_t] {
        candidates.filter { isListening(pid: $0, port: port) }
    }

    public static func isListening(pid: pid_t, port: UInt16) -> Bool {
        guard let descriptors = fileDescriptors(pid: pid) else { return false }
        for fd in descriptors where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.stride)
            let rc = proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, size)
            guard rc == size else { continue }
            let socketInfo = info.psi
            guard socketInfo.soi_kind == Int32(SOCKINFO_TCP) else { continue }
            let tcp = socketInfo.soi_proto.pri_tcp
            guard tcp.tcpsi_state == TSI_S_LISTEN else { continue }
            let localPort = UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport)
            if UInt16(bigEndian: localPort) == port { return true }
        }
        return false
    }

    /// Members of process group `pgid`.
    public static func processGroupMembers(pgid: pid_t) -> [pid_t] {
        listPids(type: UInt32(PROC_PGRP_ONLY), typeInfo: UInt32(bitPattern: pgid))
    }

    /// Every pid owned by the current real uid.
    public static func sameUserPids() -> [pid_t] {
        listPids(type: UInt32(PROC_RUID_ONLY), typeInfo: getuid())
    }

    private static func listPids(type: UInt32, typeInfo: UInt32) -> [pid_t] {
        var capacity = 1024
        for _ in 0..<5 {
            var pids = [pid_t](repeating: 0, count: capacity)
            let bytes = pids.withUnsafeMutableBufferPointer {
                proc_listpids(type, typeInfo, $0.baseAddress, Int32(capacity * MemoryLayout<pid_t>.stride))
            }
            guard bytes >= 0 else {
                logger.error("proc_listpids failed: errno \(errno, privacy: .public)")
                return []
            }
            let count = Int(bytes) / MemoryLayout<pid_t>.stride
            if count < capacity {
                return pids.prefix(count).filter { $0 > 0 }
            }
            capacity *= 2
        }
        return []
    }

    private static func fileDescriptors(pid: pid_t) -> [proc_fdinfo]? {
        let probe = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard probe > 0 else { return nil }
        var capacity = Int(probe) / MemoryLayout<proc_fdinfo>.stride + 64
        while capacity <= 1 << 20 {
            var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: capacity)
            let size = Int32(capacity * MemoryLayout<proc_fdinfo>.stride)
            let rc = descriptors.withUnsafeMutableBufferPointer {
                proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, size)
            }
            guard rc >= 0 else { return nil }
            let count = Int(rc) / MemoryLayout<proc_fdinfo>.stride
            if count < capacity { return Array(descriptors.prefix(count)) }
            capacity *= 2
        }
        return nil
    }
}

public protocol PortListenerScanning: AnyObject, Sendable {
    /// Every same-user pid listening on `port`. Runs off the main actor.
    func listeners(port: UInt16) async -> [pid_t]
    func isListening(pid: pid_t, port: UInt16) async -> Bool
}

public nonisolated final class SystemPortListenerScanner: PortListenerScanning {
    public init() {}

    public func listeners(port: UInt16) async -> [pid_t] {
        await Task.detached(priority: .utility) {
            ListeningPortScanner.listeners(port: port, among: ListeningPortScanner.sameUserPids())
        }.value
    }

    public func isListening(pid: pid_t, port: UInt16) async -> Bool {
        await Task.detached(priority: .utility) {
            ListeningPortScanner.isListening(pid: pid, port: port)
        }.value
    }
}
