// AppXPCConnectionRegistry.swift

import Foundation
import os

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "AppXPCConnectionRegistry")

/// Tracks every `NSXPCConnection` the app's anonymous listener has accepted
/// from a connected CLI (#0272 items 3–5).
///
/// A `kill -9`ed CLI leaves the app with no signal except the connection's
/// own `invalidationHandler` — there is no heartbeat, no polling, nothing
/// else to observe (item 3). `AppXPCListenerDelegate` registers every
/// accepted connection here and wires its `invalidationHandler` to
/// `unregister(id:)`, so a killed CLI's entry is reaped the moment XPC
/// notices the peer is gone, with no separate bookkeeping pass required.
///
/// Concurrent clients (item 5) fall out of keying by `ObjectIdentifier`:
/// ending one connection only ever removes that one key, and the registry's
/// `NSLock` makes register/unregister/invalidateAll safe to call from
/// whatever queue XPC delivers the connection-accept and invalidation
/// callbacks on.
///
/// Deliberately holds no reference to `AppServiceProtocol` or any exported
/// object — this is pure connection bookkeeping, independent of what the
/// connections are used for, which keeps it testable with plain
/// `NSXPCConnection(listenerEndpoint:)` instances that are never resumed.
public nonisolated final class AppXPCConnectionRegistry: @unchecked Sendable {
    private let lock = NSLock()
    /// `NSXPCConnection` is not `Sendable`
    /// (`docs/xpc/swift-concurrency-and-xpc.md` #3). `@unchecked Sendable`
    /// holds here for the same reason it holds for `Broker`'s
    /// `registeredAppEndpoint` and `XPCOnce`'s stored value: every read and
    /// write of `connections` goes through `lock`, so no two callers ever
    /// touch a stored connection concurrently, regardless of which queue
    /// XPC delivers the accept/invalidation callback on.
    private var connections: [ObjectIdentifier: NSXPCConnection] = [:]

    public init() {}

    /// Number of currently tracked connections. Logged on every transition
    /// so `log stream` shows concurrent-client count directly (#0272 item 9
    /// / the fault-injection matrix's "observable via log stream / status
    /// client count").
    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return connections.count
    }

    public func register(_ connection: NSXPCConnection) {
        let newCount: Int = {
            lock.lock()
            defer { lock.unlock() }
            connections[ObjectIdentifier(connection)] = connection
            return connections.count
        }()
        logger.info("registered connection — active clients=\(newCount, privacy: .public)")
    }

    /// Removes the connection identified by `id`. Safe to call for an
    /// already-removed or unknown id (a no-op) — the invalidation handler
    /// this is normally called from is guaranteed to fire exactly once per
    /// connection, but `invalidateAll()` racing a peer-driven invalidation
    /// on the same connection is exactly the case this tolerates.
    public func unregister(id: ObjectIdentifier) {
        let newCount: Int = {
            lock.lock()
            defer { lock.unlock() }
            connections.removeValue(forKey: id)
            return connections.count
        }()
        logger.info("unregistered connection — active clients=\(newCount, privacy: .public)")
    }

    /// Invalidates every tracked connection and clears the registry. Used
    /// when the app is quitting (#0272 item 4) so every attached CLI's
    /// connection tears down deliberately rather than being abandoned mid
    /// -teardown when the process actually exits.
    public func invalidateAll() {
        let snapshot: [NSXPCConnection] = {
            lock.lock()
            defer { lock.unlock() }
            let values = Array(connections.values)
            connections.removeAll()
            return values
        }()
        logger.info("invalidateAll: tearing down \(snapshot.count, privacy: .public) connection(s)")
        for connection in snapshot {
            connection.invalidate()
        }
    }
}
