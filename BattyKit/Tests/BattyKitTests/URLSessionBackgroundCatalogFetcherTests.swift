// URLSessionBackgroundCatalogFetcherTests.swift

import Foundation
import Testing
@testable import BattyKit

/// Answers requests for hosts a test registered, so nothing reaches the
/// network. Keyed by host, because `URLProtocol` classes are process-global
/// and tests run in parallel.
nonisolated final class StubCatalogProtocol: URLProtocol, @unchecked Sendable {
    typealias Script = @Sendable (StubCatalogProtocol) -> Void

    private static let lock = NSLock()
    nonisolated(unsafe) private static var scripts: [String: Script] = [:]
    nonisolated(unsafe) private static var stopped: [String: CheckedContinuation<Void, Never>] = [:]
    nonisolated(unsafe) private static var stoppedEarly: Set<String> = []

    static func register(host: String, script: @escaping Script) {
        lock.withLock { scripts[host] = script }
    }

    static func unregister(host: String) {
        lock.withLock {
            scripts[host] = nil
            stoppedEarly.remove(host)
        }
    }

    /// Returns once `stopLoading` has run for `host`.
    static func waitForStop(host: String) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let already = lock.withLock {
                if stoppedEarly.remove(host) != nil { return true }
                stopped[host] = continuation
                return false
            }
            if already { continuation.resume() }
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else { return false }
        return lock.withLock { scripts[host] != nil }
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let host = request.url?.host, let script = Self.lock.withLock({ Self.scripts[host] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        script(self)
    }

    override func stopLoading() {
        guard let host = request.url?.host else { return }
        let continuation: CheckedContinuation<Void, Never>? = Self.lock.withLock {
            if let waiting = Self.stopped.removeValue(forKey: host) { return waiting }
            Self.stoppedEarly.insert(host)
            return nil
        }
        continuation?.resume()
    }

    func respond(status: Int, headers: [String: String] = [:]) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    }

    func send(_ data: Data) { client?.urlProtocol(self, didLoad: data) }
    func finish() { client?.urlProtocolDidFinishLoading(self) }
}

nonisolated final class RecordedHeaders: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    func set(_ headers: [String: String]) { lock.withLock { values = headers } }
    subscript(_ name: String) -> String? { lock.withLock { values[name] } }
}

struct URLSessionBackgroundCatalogFetcherTests {
    private let host = "\(UUID().uuidString.lowercased()).stub.test"
    private let fetcher = URLSessionBackgroundCatalogFetcher(protocolClasses: [StubCatalogProtocol.self])

    private var url: URL { URL(string: "https://\(host)/catalog.json")! }

    private func failure(_ request: HostedFetchRequest) async -> HostedFetchError? {
        do {
            _ = try await fetcher.fetch(request, progress: nil)
            return nil
        } catch {
            return error
        }
    }

    @Test func aBodyStreamingPastTheLimitIsCancelled() async throws {
        defer { StubCatalogProtocol.unregister(host: host) }
        StubCatalogProtocol.register(host: host) { stub in
            stub.respond(status: 200)
            for _ in 0..<4 { stub.send(Data(repeating: 0x20, count: 400)) }
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("batty-stub-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let destination = folder.appendingPathComponent("download")
        let request = HostedFetchRequest(url: url, byteLimit: 1_000, timeout: 30, destination: .file(destination))
        #expect(await failure(request) == .tooLarge)
        await StubCatalogProtocol.waitForStop(host: host)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func aFailureBeforeTheBodyLeavesAFileTheFetcherDidNotCreate() async throws {
        defer { StubCatalogProtocol.unregister(host: host) }
        StubCatalogProtocol.register(host: host) { stub in
            stub.respond(status: 404)
            stub.finish()
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("batty-stub-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let destination = folder.appendingPathComponent("download")
        try Data("someone else's".utf8).write(to: destination)
        let request = HostedFetchRequest(url: url, byteLimit: 1_000, timeout: 30, destination: .file(destination))
        #expect(await failure(request) == .notFound)
        #expect(try Data(contentsOf: destination) == Data("someone else's".utf8))
    }

    @Test func aDeclaredLengthOverTheLimitIsRefusedBeforeTheBody() async throws {
        defer { StubCatalogProtocol.unregister(host: host) }
        StubCatalogProtocol.register(host: host) { stub in
            stub.respond(status: 200, headers: ["Content-Length": "5000"])
            // URLSession may hold the response back until the body ends; one
            // byte is far under the limit, so only the declared length refuses.
            stub.send(Data([0x7B]))
            stub.finish()
        }
        let error = await failure(HostedFetchRequest(url: url, byteLimit: 1_000, timeout: 30))
        #expect(error == .tooLarge, "got \(String(describing: error))")
    }

    @Test func conditionalHeadersAreSentAnd304IsReturned() async throws {
        defer { StubCatalogProtocol.unregister(host: host) }
        let recorded = RecordedHeaders()
        StubCatalogProtocol.register(host: host) { stub in
            recorded.set(stub.request.allHTTPHeaderFields ?? [:])
            stub.respond(status: 304, headers: ["ETag": "\"v1\""])
            stub.finish()
        }
        let request = HostedFetchRequest(url: url, etag: "\"v1\"", lastModified: "Mon, 09 Nov 2026 10:00:00 GMT", byteLimit: 1_000, timeout: 30)
        let response = try await fetcher.fetch(request, progress: nil)
        #expect(response.status == 304)
        #expect(response.body == nil)
        #expect(recorded["If-None-Match"] == "\"v1\"")
        #expect(recorded["If-Modified-Since"] == "Mon, 09 Nov 2026 10:00:00 GMT")
    }

    @Test func aRedirectToHTTPFails() async throws {
        defer { StubCatalogProtocol.unregister(host: host) }
        let target = URL(string: "http://\(host)/elsewhere.json")!
        StubCatalogProtocol.register(host: host) { stub in
            let response = HTTPURLResponse(url: stub.request.url!, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": target.absoluteString])!
            stub.client?.urlProtocol(stub, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
        }
        #expect(await failure(HostedFetchRequest(url: url, byteLimit: 1_000, timeout: 30)) == .insecureRedirect)
    }
}
