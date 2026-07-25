// AppXPCConnectionRegistryTests.swift

import Foundation
import Testing
@testable import BattyKit

/// Covers the orphan-reaping bookkeeping behind #0272 items 3 and 5 — no
/// real XPC peer involved. `NSXPCConnection(listenerEndpoint:)` against a
/// freshly created anonymous listener's endpoint gives each test a distinct,
/// identity-comparable connection object without ever resuming or
/// connecting it, which is all the registry's bookkeeping needs: it never
/// dereferences the connection, only keys by `ObjectIdentifier`.
struct AppXPCConnectionRegistryTests {

    private func makeConnection() -> NSXPCConnection {
        NSXPCConnection(listenerEndpoint: NSXPCListener.anonymous().endpoint)
    }

    @Test func registerIncrementsCount() {
        let registry = AppXPCConnectionRegistry()
        #expect(registry.count == 0)
        registry.register(makeConnection())
        #expect(registry.count == 1)
    }

    @Test func unregisterByIdRemovesTheMatchingConnectionOnly() {
        // The core of item 5 — "ending one must not disturb the other":
        // two concurrent connections, unregistering one leaves the other's
        // count intact.
        let registry = AppXPCConnectionRegistry()
        let first = makeConnection()
        let second = makeConnection()
        registry.register(first)
        registry.register(second)
        #expect(registry.count == 2)

        registry.unregister(id: ObjectIdentifier(first))
        #expect(registry.count == 1)

        registry.unregister(id: ObjectIdentifier(second))
        #expect(registry.count == 0)
    }

    @Test func unregisteringAnUnknownIdIsANoOp() {
        // The invalidation handler this is normally driven from is
        // guaranteed to fire exactly once per connection, but a stray
        // second call (or a call for a connection that was never
        // registered) must not crash or affect other entries.
        let registry = AppXPCConnectionRegistry()
        registry.register(makeConnection())
        #expect(registry.count == 1)
        registry.unregister(id: ObjectIdentifier(makeConnection()))
        #expect(registry.count == 1)
    }

    @Test func unregisteringTheSameIdTwiceIsHarmless() {
        let registry = AppXPCConnectionRegistry()
        let connection = makeConnection()
        registry.register(connection)
        registry.unregister(id: ObjectIdentifier(connection))
        registry.unregister(id: ObjectIdentifier(connection))
        #expect(registry.count == 0)
    }

    @Test func invalidateAllClearsTheRegistry() {
        // #0272 item 4: quitting tears every attached connection down
        // deliberately. The registry side of that is emptying out — the
        // actual `invalidate()` call on each connection isn't something
        // this test can observe without a live peer, but an empty registry
        // afterward is the invariant `prepareForTermination()` depends on
        // (a stale entry here would mean a later access touches a
        // connection object already torn down).
        let registry = AppXPCConnectionRegistry()
        registry.register(makeConnection())
        registry.register(makeConnection())
        registry.register(makeConnection())
        #expect(registry.count == 3)

        registry.invalidateAll()
        #expect(registry.count == 0)
    }

    @Test func invalidateAllOnAnEmptyRegistryIsHarmless() {
        let registry = AppXPCConnectionRegistry()
        registry.invalidateAll()
        #expect(registry.count == 0)
    }
}
