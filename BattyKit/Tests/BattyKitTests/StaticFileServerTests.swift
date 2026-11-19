// StaticFileServerTests.swift

import Foundation
import Network
import Testing
@testable import BattyKit

/// A real loopback listener per test. Every await is bounded by the hang
/// guard; each test stops its server in a `defer`, so a failed
/// `#require` never leaves a listener open, and awaits `waitUntilStopped()`
/// on the success path.
nonisolated struct StaticFileServerTests {
    private func makeServer(_ fixture: StaticServerFixture, inject: Bool = true) throws -> StaticFileServer {
        StaticFileServer(resolver: try #require(StaticFilePathResolver(root: fixture.root)), injectsReloadScript: inject)
    }

    private func started(_ server: StaticFileServer, port: UInt16? = nil) async throws -> UInt16 {
        let result = await boundedValue { () -> Result<UInt16, StaticServerError> in
            do throws(StaticServerError) { return .success(try await server.start(port: port)) } catch { return .failure(error) }
        }
        return try #require(result).get()
    }

    private func shutDown(_ server: StaticFileServer) async {
        server.stop()
        #expect(await awaitBounded { await server.waitUntilStopped() })
    }

    @Test func ephemeralPortIsLoopbackAndServesIndex() async throws {
        let fixture = try StaticServerFixture()
        defer { fixture.remove() }
        let server = try makeServer(fixture)
        defer { server.stop() }
        let port = try await started(server)
        #expect(port != 0)
        let response = try #require(await boundedValue { await RawHTTPTestClient.send(RawHTTPTestClient.get("/", port: port), port: port) } ?? nil)
        #expect(response.status == 200)
        #expect(response.bodyText.contains("<h1>index</h1>"))
        #expect(response.headers["connection"] == "close")
        await shutDown(server)
    }

    @Test func rawDotDotRequestIs403() async throws {
        let fixture = try StaticServerFixture()
        defer { fixture.remove() }
        let server = try makeServer(fixture)
        defer { server.stop() }
        let port = try await started(server)
        for target in ["/../outside/secret.txt", "/%2e%2e/outside/secret.txt", "/..%2foutside/secret.txt"] {
            let response = try #require(await boundedValue { await RawHTTPTestClient.send(RawHTTPTestClient.get(target, port: port), port: port) } ?? nil)
            #expect(response.status == 403)
            #expect(!response.bodyText.contains("outside secret"))
        }
        await shutDown(server)
    }

    @Test func symlinkOutsideRootIs403OverTheWire() async throws {
        let fixture = try StaticServerFixture()
        defer { fixture.remove() }
        let server = try makeServer(fixture)
        defer { server.stop() }
        let port = try await started(server)
        let response = try #require(await boundedValue { await RawHTTPTestClient.send(RawHTTPTestClient.get("/outside-link.txt", port: port), port: port) } ?? nil)
        #expect(response.status == 403)
        #expect(!response.bodyText.contains("outside secret"))
        await shutDown(server)
    }

    @Test func dotfileIs404() async throws {
        let fixture = try StaticServerFixture()
        defer { fixture.remove() }
        let server = try makeServer(fixture)
        defer { server.stop() }
        let port = try await started(server)
        let response = try #require(await boundedValue { await RawHTTPTestClient.send(RawHTTPTestClient.get("/.env", port: port), port: port) } ?? nil)
        #expect(response.status == 404)
        #expect(!response.bodyText.contains("SECRET"))
        await shutDown(server)
    }

    @Test func foreignHostIs403OverTheWire() async throws {
        let fixture = try StaticServerFixture()
        defer { fixture.remove() }
        let server = try makeServer(fixture)
        defer { server.stop() }
        let port = try await started(server)
        let raw = "GET / HTTP/1.1\r\nHost: rebound.example:\(port)\r\n\r\n"
        let response = try #require(await boundedValue { await RawHTTPTestClient.send(raw, port: port) } ?? nil)
        #expect(response.status == 403)
        await shutDown(server)
    }

    @Test func busyPortFailsWithPortInUse() async throws {
        let fixture = try StaticServerFixture()
        defer { fixture.remove() }
        let holder = try makeServer(fixture)
        defer { holder.stop() }
        let port = try await started(holder)
        let second = try makeServer(fixture)
        defer { second.stop() }
        let result = await boundedValue { () -> Result<UInt16, StaticServerError> in
            do throws(StaticServerError) { return .success(try await second.start(port: port)) } catch { return .failure(error) }
        }
        #expect(result == Result<UInt16, StaticServerError>.failure(.portInUse(Int(port))))
        await shutDown(second)
        await shutDown(holder)
    }

    @Test func stopFreesThePortForANewServer() async throws {
        let fixture = try StaticServerFixture()
        defer { fixture.remove() }
        let first = try makeServer(fixture)
        defer { first.stop() }
        let port = try await started(first)
        await shutDown(first)
        let second = try makeServer(fixture)
        defer { second.stop() }
        let again = try await started(second, port: port)
        #expect(again == port)
        await shutDown(second)
    }

    @Test func requestCountCounts() async throws {
        let fixture = try StaticServerFixture()
        defer { fixture.remove() }
        let server = try makeServer(fixture)
        defer { server.stop() }
        let port = try await started(server)
        for _ in 0..<3 {
            _ = await boundedValue { await RawHTTPTestClient.send(RawHTTPTestClient.get("/", port: port), port: port) }
        }
        #expect(server.stats.requestCount == 3)
        await shutDown(server)
    }

    @Test func sseClientReceivesReloadOnBroadcast() async throws {
        let fixture = try StaticServerFixture()
        defer { fixture.remove() }
        let server = try makeServer(fixture)
        defer { server.stop() }
        let port = try await started(server)
        let stream = RawHTTPTestClient.stream(RawHTTPTestClient.get(ReloadScriptInjector.endpoint, port: port), port: port)
        let text = await boundedValue { () -> String in
            var received = ""
            var broadcast = false
            for await chunk in stream {
                received += String(decoding: chunk, as: UTF8.self)
                if !broadcast, received.contains(": connected") {
                    broadcast = true
                    server.broadcastReload()
                }
                if received.contains("data: reload\n\n") { break }
            }
            return received
        }
        #expect(text?.contains("text/event-stream") == true)
        #expect(text?.contains("data: reload\n\n") == true)
        #expect(server.stats.reloadClientCount == 1)
        await shutDown(server)
    }

    @Test func stopClosesSSEClients() async throws {
        let fixture = try StaticServerFixture()
        defer { fixture.remove() }
        let server = try makeServer(fixture)
        defer { server.stop() }
        let port = try await started(server)
        let stream = RawHTTPTestClient.stream(RawHTTPTestClient.get(ReloadScriptInjector.endpoint, port: port), port: port)
        let reachedEOF = await awaitBounded {
            var stopped = false
            for await chunk in stream where !stopped && String(decoding: chunk, as: UTF8.self).contains(": connected") {
                stopped = true
                server.stop()
            }
        }
        #expect(reachedEOF)
        #expect(await awaitBounded { await server.waitUntilStopped() })
    }

    @Test(.enabled(if: NonLoopbackAddress.firstIPv4 != nil, "needs an en* IPv4 address"))
    func notReachableOnANonLoopbackAddress() async throws {
        let fixture = try StaticServerFixture()
        defer { fixture.remove() }
        let server = try makeServer(fixture)
        defer { server.stop() }
        let port = try await started(server)
        let address = try #require(NonLoopbackAddress.firstIPv4)
        #expect(await boundedValue { await RawHTTPTestClient.canConnect(host: address, port: port) } == false)
        #expect(await boundedValue { await RawHTTPTestClient.canConnect(host: "127.0.0.1", port: port) } == true)
        await shutDown(server)
    }
}

nonisolated struct FSEventsDirectoryWatcherTests {
    @Test func reportsAFileWrittenUnderTheRoot() async throws {
        let fixture = try StaticServerFixture()
        defer { fixture.remove() }
        let root = try #require(StaticFilePathResolver.realPath(fixture.root.path))
        let watcher = FSEventsDirectoryWatcher(root: root)
        let (events, continuation) = AsyncStream<[String]>.makeStream()
        watcher.start { continuation.yield($0) }
        defer { watcher.stop() }
        try Data("changed".utf8).write(to: fixture.root.appendingPathComponent("sub/page.html"))
        let paths = await boundedValue { () -> [String] in
            for await batch in events where batch.contains(where: { $0.hasSuffix("/sub/page.html") }) {
                return batch
            }
            return []
        }
        #expect(paths?.contains { $0.hasSuffix("/sub/page.html") } == true)
    }
}

@MainActor
struct StaticReloadDebouncerTests {
    @Test func burstOfChangesFiresOnce() async {
        let clock = TestClock()
        let broadcaster = StaticReloadBroadcaster()
        let debouncer = StaticReloadDebouncer(clock: clock, broadcaster: broadcaster)
        debouncer.noteChange()
        debouncer.noteChange()
        debouncer.noteChange()
        #expect(await clock.waitForSleepers(1))
        await clock.advance(by: .milliseconds(150))
        await debouncer.pending?.value
        #expect(broadcaster.changeCount == 1)
    }

    @Test func firesOnlyAfterTheQuietPeriod() async {
        let clock = TestClock()
        let broadcaster = StaticReloadBroadcaster()
        let debouncer = StaticReloadDebouncer(clock: clock, broadcaster: broadcaster)
        debouncer.noteChange()
        #expect(await clock.waitForSleepers(1))
        #expect(await clock.advance(by: .milliseconds(149)) == 0)
        #expect(broadcaster.changeCount == 0)
        #expect(await clock.advance(by: .milliseconds(1)) == 1)
        await debouncer.pending?.value
        #expect(broadcaster.changeCount == 1)
        #expect(broadcaster.lastChangeAt == clock.now)
    }

    @Test func stopCancelsAPendingFire() async {
        let clock = TestClock()
        let broadcaster = StaticReloadBroadcaster()
        let debouncer = StaticReloadDebouncer(clock: clock, broadcaster: broadcaster)
        debouncer.noteChange()
        #expect(await clock.waitForSleepers(1))
        let pending = debouncer.pending
        debouncer.stop()
        await pending?.value
        #expect(broadcaster.changeCount == 0)
    }

    @Test func observersAndBroadcastBothFire() async {
        let clock = TestClock()
        let broadcaster = StaticReloadBroadcaster()
        var serverFired = 0
        var observerFired = 0
        broadcaster.onBroadcast = { serverFired += 1 }
        let id = broadcaster.addObserver { observerFired += 1 }
        let debouncer = StaticReloadDebouncer(clock: clock, broadcaster: broadcaster)
        debouncer.noteChange()
        #expect(await clock.waitForSleepers(1))
        await clock.advance(by: .milliseconds(150))
        await debouncer.pending?.value
        #expect(serverFired == 1)
        #expect(observerFired == 1)
        broadcaster.removeObserver(id)
        #expect(broadcaster.observerCount == 0)
    }
}
