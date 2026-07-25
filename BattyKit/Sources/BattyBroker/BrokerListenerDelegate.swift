// BrokerListenerDelegate.swift

import BattyXPCCore
import Foundation
import os

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "BrokerListenerDelegate")

/// `NSXPCListenerDelegate` is a Foundation-supplied protocol, not one of
/// this project's own `@objc` protocols — its requirement can't be marked
/// `nonisolated` at the declaration site the way `BrokerProtocol` is (see
/// #0269 Gotchas, "three protocol requirements ... unguarded"). The whole
/// class being `nonisolated` is what keeps this off the main actor.
nonisolated final class BrokerListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let exportedObject: Broker

    init(exportedObject: Broker) {
        self.exportedObject = exportedObject
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = XPCInterfaces.broker
        // The `as any BrokerProtocol` cast is load-bearing, not decorative:
        // it is the compile-time guard that `Broker` stays `nonisolated`.
        // `exportedObject` alone is typed `Any?`, so assigning the bare
        // `Broker` instance compiles regardless of the class's isolation.
        // Forcing the existential conversion here means a future edit that
        // drops `nonisolated` from `final class Broker` fails to build with
        // `main actor-isolated conformance of 'Broker' to 'BrokerProtocol'
        // cannot be used in nonisolated context [#IsolatedConformances]`
        // instead of silently shipping a main-actor-isolated object that
        // XPC invokes off the main queue.
        newConnection.exportedObject = exportedObject as any BrokerProtocol

        // Distinct interruption/invalidation handling (#0272 item 1). The
        // broker itself holds no per-connection state worth reaping on
        // interruption — nothing to retry from the broker's side, since it
        // never initiates calls — so interruption is logged only, for
        // `log stream` visibility. Invalidation is the one that matters:
        // if the invalidating connection is the one that most recently
        // called `registerAppEndpoint`, the stored endpoint is now a Mach
        // right nothing is listening on, and `connectionDidInvalidate`
        // clears it rather than leaving the broker to hand out a stale
        // endpoint to the next CLI that asks (#0272 item 2's spirit).
        let identifier = ObjectIdentifier(newConnection)
        let broker = exportedObject
        newConnection.interruptionHandler = { @Sendable in
            logger.notice("connection interrupted")
        }
        newConnection.invalidationHandler = { @Sendable in
            broker.connectionDidInvalidate(identifier)
            logger.info("connection invalidated")
        }

        newConnection.resume()
        logger.info("accepted new connection")
        return true
    }
}
