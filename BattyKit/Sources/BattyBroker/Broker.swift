// Broker.swift

import BattyXPCCore
import Foundation
import os

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "Broker")

/// The broker's whole job: answer a liveness ping, store one endpoint, hand
/// it out. No app logic, nothing worth persisting — being restartable
/// without consequence is what makes the arrangement robust.
///
/// Must be a `nonisolated final class`, not `@MainActor`. To be precise
/// about what actually fails: a `@MainActor` type's conformance to
/// `BrokerProtocol` *compiles* fine — the error only appears where that
/// conformance is *used* from a nonisolated context, e.g. handing the
/// instance to XPC as `any BrokerProtocol`
/// (`BrokerListenerDelegate.swift`), which is exactly what every real
/// caller here does. That use site fails with `main actor-isolated
/// conformance of 'Broker' to 'BrokerProtocol' cannot be used in
/// nonisolated context [#IsolatedConformances]` (see #0269 Gotchas). XPC
/// delivers on its own queues regardless, so this class stays nonisolated.
/// `@unchecked Sendable`: every stored property below is only ever touched
/// under `lock`, so no two callers observe or mutate `registeredAppEndpoint`
/// / `registeringConnectionID` concurrently regardless of which XPC queue
/// invokes a given protocol method or `connectionDidInvalidate(_:)` — the
/// same reasoning `AppXPCConnectionRegistry` documents for its own
/// `NSXPCConnection` storage. Needed so `BrokerListenerDelegate` can capture
/// `exportedObject` (this instance) inside the `@Sendable` invalidation
/// handler it installs on every accepted connection (#0272 item 1/2).
nonisolated final class Broker: NSObject, BrokerProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var registeredAppEndpoint: NSXPCListenerEndpoint?
    /// Identifies which accepted connection most recently called
    /// `registerAppEndpoint(_:)` — captured via `NSXPCConnection.current()`
    /// rather than added as a protocol parameter, so `BrokerProtocol`'s wire
    /// shape is unchanged. Used to clear a stale endpoint the moment *that*
    /// connection invalidates (the app died or quit), so the broker stops
    /// handing out a Mach right nothing is listening on (#0272 item 2's
    /// spirit: don't make a CLI discover staleness the hard way).
    private var registeringConnectionID: ObjectIdentifier?

    func brokerPing(reply: @escaping @Sendable (String) -> Void) {
        let description = "pid \(ProcessInfo.processInfo.processIdentifier)"
        logger.info("brokerPing -> \(description, privacy: .public)")
        reply(description)
    }

    func registerAppEndpoint(_ endpoint: NSXPCListenerEndpoint) {
        let identifier = NSXPCConnection.current().map(ObjectIdentifier.init)
        lock.lock()
        registeredAppEndpoint = endpoint
        registeringConnectionID = identifier
        lock.unlock()
        logger.info("app endpoint registered")
    }

    func appEndpoint(reply: @escaping @Sendable (NSXPCListenerEndpoint?) -> Void) {
        lock.lock()
        let endpoint = registeredAppEndpoint
        lock.unlock()
        reply(endpoint)
    }

    /// Called from the invalidation handler `BrokerListenerDelegate` installs
    /// on every accepted connection. Clears the stored endpoint only if
    /// `identifier` is the connection that registered it — a CLI's
    /// connection invalidating (the common case; every `batty` invocation is
    /// one) must never clear the app's registration.
    func connectionDidInvalidate(_ identifier: ObjectIdentifier) {
        let cleared: Bool = {
            lock.lock()
            defer { lock.unlock() }
            guard registeringConnectionID == identifier else { return false }
            registeredAppEndpoint = nil
            registeringConnectionID = nil
            return true
        }()
        if cleared {
            logger.notice("registering connection invalidated — cleared stale app endpoint")
        }
    }
}
