// AppXPCListenerDelegate.swift

import BattyXPCCore
import Foundation
import os

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "AppXPCListenerDelegate")

/// `NSXPCListenerDelegate` is a Foundation-supplied protocol, not one of
/// this project's own `@objc` protocols — its requirement can't be marked
/// `nonisolated` at the declaration site the way `AppServiceProtocol` is
/// (see #0269 Gotchas, "three protocol requirements ... unguarded", and
/// `BrokerListenerDelegate.swift` for the broker's identical shape). The
/// whole class being `nonisolated` is what keeps this off the main actor.
nonisolated final class AppXPCListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let exportedObject: AppXPCService
    private let connectionRegistry: AppXPCConnectionRegistry

    init(exportedObject: AppXPCService, connectionRegistry: AppXPCConnectionRegistry) {
        self.exportedObject = exportedObject
        self.connectionRegistry = connectionRegistry
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = XPCInterfaces.appService
        // The `as any AppServiceProtocol` cast is load-bearing, not
        // decorative — see `BrokerListenerDelegate.swift` for the identical
        // reasoning on the broker side. `exportedObject` alone is typed
        // `Any?`, so assigning the bare `AppXPCService` instance compiles
        // regardless of the class's isolation. Forcing the existential
        // conversion here means a future edit that drops `nonisolated` from
        // `final class AppXPCService` fails to build with `main
        // actor-isolated conformance of 'AppXPCService' to
        // 'AppServiceProtocol' cannot be used in nonisolated context
        // [#IsolatedConformances]` instead of silently shipping a
        // main-actor-isolated object that XPC invokes off the main queue.
        newConnection.exportedObject = exportedObject as any AppServiceProtocol

        // Orphan reaping (#0272 item 3): a `kill -9`ed CLI gives the app no
        // signal except this connection's own invalidation — there is no
        // heartbeat to poll instead. Capturing only the Sendable
        // `ObjectIdentifier`, not `newConnection` itself, keeps the closure
        // `@Sendable`-clean without a boxing type: the connection is never
        // read back out of the closure, only used to compute a value before
        // the closure is built.
        let identifier = ObjectIdentifier(newConnection)
        let registry = connectionRegistry
        newConnection.interruptionHandler = { @Sendable in
            // Peer-died-but-reusable has no meaning for a short-lived
            // request/reply connection the CLI process is about to tear
            // down regardless — nothing to retry from the app's side, so
            // this exists to make the distinct signal visible in
            // `log stream` rather than to trigger different app behavior
            // (contrast `AppXPCCoordinator`'s persistent broker connection,
            // where interruption vs invalidation drives different actions).
            logger.notice("client connection interrupted")
        }
        newConnection.invalidationHandler = { @Sendable in
            registry.unregister(id: identifier)
            logger.info("client connection invalidated")
        }
        connectionRegistry.register(newConnection)

        newConnection.resume()
        logger.info("accepted new connection")
        return true
    }
}
