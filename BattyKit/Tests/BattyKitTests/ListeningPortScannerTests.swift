// ListeningPortScannerTests.swift

import Darwin
import Foundation
import Testing
@testable import BattyKit

/// A TCP socket bound to 127.0.0.1 on an ephemeral port.
nonisolated final class LoopbackSocket {
    let fd: Int32
    let port: UInt16

    init(listen shouldListen: Bool = true) throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { close(fd); throw POSIXError(.EADDRINUSE) }
        if shouldListen { Darwin.listen(fd, 4) }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        self.fd = fd
        port = UInt16(bigEndian: actual.sin_port)
    }

    deinit { close(fd) }
}

nonisolated struct ListeningPortScannerTests {
    @Test func findsThisProcessListeningOnABoundPort() throws {
        let socket = try LoopbackSocket()
        #expect(ListeningPortScanner.listeners(port: socket.port, among: [getpid()]) == [getpid()])
        #expect(ListeningPortScanner.listeners(port: socket.port, among: ListeningPortScanner.sameUserPids()).contains(getpid()))
    }

    @Test func ignoresAConnectedNonListeningSocket() throws {
        let server = try LoopbackSocket()
        let client = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        defer { close(client) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = server.port.bigEndian
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(client, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        #expect(connected == 0)
        var local = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(client, $0, &length) }
        }
        let clientPort = UInt16(bigEndian: local.sin_port)
        #expect(ListeningPortScanner.listeners(port: clientPort, among: [getpid()]).isEmpty)
    }

    @Test func returnsNothingForAPortNobodyListensOn() throws {
        let port: UInt16
        do {
            let unused = try LoopbackSocket(listen: false)
            port = unused.port
        }
        #expect(ListeningPortScanner.listeners(port: port, among: [getpid()]).isEmpty)
    }

    @Test func processGroupMembersIncludesThisProcess() {
        #expect(ListeningPortScanner.processGroupMembers(pgid: getpgrp()).contains(getpid()))
    }
}
