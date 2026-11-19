// RawHTTPTestClient.swift

import Foundation
import Network
import os

/// Runs `operation` under the hang guard and returns its value, or nil when
/// the guard expired.
nonisolated func boundedValue<T: Sendable>(_ operation: @escaping @Sendable () async -> T) async -> T? {
    let box = OSAllocatedUnfairLock<T?>(initialState: nil)
    let finished = await awaitBounded {
        let value = await operation()
        box.withLock { $0 = value }
    }
    return finished ? box.withLock { $0 } : nil
}

nonisolated struct RawHTTPResponse {
    let status: Int
    let headers: [String: String]
    let body: Data

    var bodyText: String { String(decoding: body, as: UTF8.self) }

    init?(_ data: Data) {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: data[data.startIndex..<end.lowerBound], encoding: .utf8) else { return nil }
        var lines = head.components(separatedBy: "\r\n")
        let statusLine = lines.removeFirst().split(separator: " ")
        guard statusLine.count >= 2, let status = Int(statusLine[1]) else { return nil }
        self.status = status
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        self.headers = headers
        body = data[end.upperBound...]
    }
}

/// Sends exact bytes over a TCP connection, so a test can send `..` that a
/// URL type would normalize away.
nonisolated enum RawHTTPTestClient {
    static func get(_ target: String, port: UInt16, headers: [String: String] = [:]) -> String {
        var text = "GET \(target) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n"
        for (name, value) in headers { text += "\(name): \(value)\r\n" }
        return text + "\r\n"
    }

    /// The whole response, read to EOF. Nil when the connection failed.
    static func send(_ raw: String, port: UInt16, host: String = "127.0.0.1") async -> RawHTTPResponse? {
        let data: Data? = await withCheckedContinuation { continuation in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            let finish: @Sendable (Data?) -> Void = { value in
                let first = resumed.withLock { done -> Bool in defer { done = true }; return !done }
                if first { continuation.resume(returning: value) }
            }
            let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
            let queue = DispatchQueue(label: "RawHTTPTestClient")
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(content: Data(raw.utf8), completion: .contentProcessed { _ in })
                    readToEnd(connection, buffer: Data()) { data in
                        connection.cancel()
                        finish(data)
                    }
                case .failed, .waiting:
                    connection.cancel()
                    finish(nil)
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
        return data.flatMap(RawHTTPResponse.init)
    }

    /// Whether a TCP connection to `host:port` reaches `.ready`.
    static func canConnect(host: String, port: UInt16) async -> Bool {
        await withCheckedContinuation { continuation in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
            let finish: @Sendable (Bool) -> Void = { value in
                let first = resumed.withLock { done -> Bool in defer { done = true }; return !done }
                if first {
                    connection.cancel()
                    continuation.resume(returning: value)
                }
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(true)
                case .failed, .waiting: finish(false)
                default: break
                }
            }
            connection.start(queue: DispatchQueue(label: "RawHTTPTestClient.connect"))
        }
    }

    /// Chunks as they arrive; the stream finishes at EOF. Terminating the
    /// stream closes the connection.
    static func stream(_ raw: String, port: UInt16) -> AsyncStream<Data> {
        AsyncStream { continuation in
            let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
            continuation.onTermination = { _ in connection.cancel() }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(content: Data(raw.utf8), completion: .contentProcessed { _ in })
                    readChunks(connection, continuation)
                case .failed, .waiting, .cancelled:
                    continuation.finish()
                default:
                    break
                }
            }
            connection.start(queue: DispatchQueue(label: "RawHTTPTestClient.stream"))
        }
    }

    private static func readToEnd(_ connection: NWConnection, buffer: Data, done: @escaping @Sendable (Data) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, isComplete, error in
            var next = buffer
            if let data { next.append(data) }
            if isComplete || error != nil {
                done(next)
            } else {
                readToEnd(connection, buffer: next, done: done)
            }
        }
    }

    private static func readChunks(_ connection: NWConnection, _ continuation: AsyncStream<Data>.Continuation) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { data, _, isComplete, error in
            if let data, !data.isEmpty { continuation.yield(data) }
            if isComplete || error != nil {
                continuation.finish()
            } else {
                readChunks(connection, continuation)
            }
        }
    }
}

nonisolated enum NonLoopbackAddress {
    /// The first IPv4 address on an `en*` interface, if the Mac has one.
    static let firstIPv4: String? = {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  String(cString: entry.ifa_name).hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                return String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            }
        }
        return nil
    }()
}
