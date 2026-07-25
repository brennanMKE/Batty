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

    init(exportedObject: AppXPCService) {
        self.exportedObject = exportedObject
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
        newConnection.resume()
        logger.info("accepted new connection")
        return true
    }
}
