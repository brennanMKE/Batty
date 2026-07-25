// PendingRequestRegistryTests.swift

import BattyXPCCore
import Foundation
import Testing
@testable import BattyKit

/// Trivial `NSLock`-guarded box so test closures can record what a
/// `@Sendable (Data) -> Void` reply received without tripping strict
/// concurrency's "mutation of captured var in concurrently-executing code"
/// — every call in these tests happens synchronously inline, but the
/// closure's *type* is `@Sendable`, so the compiler must be shown a
/// thread-safe capture regardless.
private nonisolated final class Recorder<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Value] = []

    func record(_ value: Value) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    var all: [Value] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }

    var count: Int { all.count }
    var first: Value? { all.first }
}

/// Covers the in-flight-request bookkeeping behind #0272 item 4 (telling a
/// connected CLI the app is quitting rather than letting it learn only from
/// the connection dropping) — no XPC involved; `reply` closures here are
/// plain captured expectations, not real Foundation completion handlers.
struct PendingRequestRegistryTests {

    @Test func resolveDeliversTheDataToTheRegisteredReply() {
        let registry = PendingRequestRegistry()
        let received = Recorder<Data>()
        let id = registry.register { data in received.record(data) }
        let payload = Data("ok".utf8)
        #expect(registry.resolve(id, with: payload))
        #expect(received.first == payload)
    }

    @Test func resolveOnAnUnknownIdReturnsFalseAndCallsNothing() {
        let registry = PendingRequestRegistry()
        let calls = Recorder<Void>()
        _ = registry.register { _ in calls.record(()) }
        let unknownID = UUID()
        #expect(!registry.resolve(unknownID, with: Data()))
        #expect(calls.count == 0)
    }

    @Test func resolvingTwiceOnlyFiresTheReplyOnce() {
        // The double-resolve guard: a request already answered (normal
        // reply) must not fire again if something else races it (e.g.
        // `terminateAll()` on a request that just finished).
        let registry = PendingRequestRegistry()
        let calls = Recorder<Void>()
        let id = registry.register { _ in calls.record(()) }
        #expect(registry.resolve(id, with: Data()))
        #expect(!registry.resolve(id, with: Data()))
        #expect(calls.count == 1)
    }

    @Test func countReflectsOnlyStillPendingRequests() {
        let registry = PendingRequestRegistry()
        let first = registry.register { _ in }
        _ = registry.register { _ in }
        #expect(registry.count == 2)
        registry.resolve(first, with: Data())
        #expect(registry.count == 1)
    }

    @Test func terminateAllRepliesEveryPendingRequestWithTheTerminationSentinel() {
        let registry = PendingRequestRegistry()
        let received = Recorder<XPCResponse>()
        _ = registry.register { data in
            if let response = try? JSONDecoder().decode(XPCResponse.self, from: data) {
                received.record(response)
            }
        }
        _ = registry.register { data in
            if let response = try? JSONDecoder().decode(XPCResponse.self, from: data) {
                received.record(response)
            }
        }
        registry.terminateAll()
        #expect(received.count == 2)
        for response in received.all {
            #expect(!response.ok)
            #expect(response.error == XPCTerminationSignal.appTerminating)
        }
        #expect(registry.count == 0)
    }

    @Test func terminateAllDoesNotDoubleFireARequestAlreadyResolved() {
        let registry = PendingRequestRegistry()
        let calls = Recorder<Void>()
        let id = registry.register { _ in calls.record(()) }
        #expect(registry.resolve(id, with: Data()))
        registry.terminateAll()
        #expect(calls.count == 1)
    }

    @Test func terminateAllOnAnEmptyRegistryIsHarmless() {
        let registry = PendingRequestRegistry()
        registry.terminateAll()
        #expect(registry.count == 0)
    }

    @Test func resolveAfterTerminateAllReturnsFalse() {
        // The mirror case: a reply that arrives *after* shutdown already
        // answered on its behalf must not fire twice either.
        let registry = PendingRequestRegistry()
        let calls = Recorder<Void>()
        let id = registry.register { _ in calls.record(()) }
        registry.terminateAll()
        #expect(!registry.resolve(id, with: Data()))
        #expect(calls.count == 1)
    }
}
