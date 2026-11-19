// URLSessionHTTPProbeTests.swift

import Darwin
import Foundation
import Testing
@testable import BattyKit

nonisolated struct URLSessionHTTPProbeTests {
    @Test func answersWithTheStatusFromALoopbackListener() async throws {
        let server = try LoopbackSocket()
        let fd = server.fd
        let responder = Task.detached {
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            var buffer = [UInt8](repeating: 0, count: 4096)
            _ = read(client, &buffer, buffer.count)
            let response = "HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n"
            _ = response.withCString { write(client, $0, strlen($0)) }
            close(client)
        }
        let probe = URLSessionHTTPProbe()
        let result = await probe.probe(URL(string: "http://127.0.0.1:\(server.port)/")!)
        await responder.value
        #expect(result == .answered(status: 204))
    }

    @Test func noResponseWhenNothingListens() async throws {
        let port: UInt16
        do {
            let unused = try LoopbackSocket(listen: false)
            port = unused.port
        }
        let result = await URLSessionHTTPProbe().probe(URL(string: "http://127.0.0.1:\(port)/")!)
        guard case .noResponse = result else {
            Issue.record("expected no response, got \(result)")
            return
        }
    }
}
