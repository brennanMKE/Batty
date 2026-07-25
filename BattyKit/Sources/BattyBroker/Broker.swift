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
nonisolated final class Broker: NSObject, BrokerProtocol {
    private let lock = NSLock()
    private var registeredAppEndpoint: NSXPCListenerEndpoint?

    func brokerPing(reply: @escaping @Sendable (String) -> Void) {
        let description = "pid \(ProcessInfo.processInfo.processIdentifier)"
        logger.info("brokerPing -> \(description, privacy: .public)")
        reply(description)
    }

    func registerAppEndpoint(_ endpoint: NSXPCListenerEndpoint) {
        lock.lock()
        registeredAppEndpoint = endpoint
        lock.unlock()
        logger.info("app endpoint registered")
    }

    func appEndpoint(reply: @escaping @Sendable (NSXPCListenerEndpoint?) -> Void) {
        lock.lock()
        let endpoint = registeredAppEndpoint
        lock.unlock()
        reply(endpoint)
    }
}
