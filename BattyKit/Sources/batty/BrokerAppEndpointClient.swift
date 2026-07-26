// BrokerAppEndpointClient.swift

import BattyXPCCore
import Foundation
import os

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "BrokerAppEndpointClient")

/// Synchronous XPC round trip to the broker's `appEndpoint`, step 2 of the
/// CLI's five-step connect dance (`docs/xpc/xpc-cli-architecture.md`).
///
/// Distinguishes "the broker itself is unreachable" from "the broker is
/// reachable but no app has registered yet" — the caller needs that
/// distinction to choose between exiting `2` immediately and proceeding to
/// launch-and-poll (see `AppConnectDance.swift`).
nonisolated enum BrokerAppEndpointClient {
    enum Result: Sendable {
        case unreachable
        case endpoint(NSXPCListenerEndpoint?)
    }

    static func fetchEndpoint(timeout: TimeInterval) -> Result {
        let once = XPCOnce<Result>(defaultValue: .unreachable)
        let connection = NSXPCConnection(machServiceName: ServiceNames.broker)
        connection.remoteObjectInterface = XPCInterfaces.broker
        // #0278: reject an impostor occupying the broker's Mach service
        // name — this call is the one that would hand an attacker-supplied
        // app endpoint back to the CLI if the broker were spoofed.
        OutgoingCodeSigningEnforcement.apply(to: connection, context: "CLI→broker (appEndpoint)")
        connection.interruptionHandler = { @Sendable in
            logger.notice("appEndpoint: broker connection interrupted")
            once.finish(.unreachable)
        }
        connection.invalidationHandler = { @Sendable in
            logger.notice("appEndpoint: broker connection invalidated")
            once.finish(.unreachable)
        }
        connection.resume()

        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ @Sendable error in
            logger.error("appEndpoint: broker unreachable — \(error.localizedDescription, privacy: .public)")
            once.finish(.unreachable)
        }) as? BrokerProtocol else {
            logger.error("appEndpoint: failed to obtain broker proxy")
            connection.invalidate()
            return .unreachable
        }

        proxy.appEndpoint { @Sendable endpoint in
            once.finish(.endpoint(endpoint))
        }

        let result = once.wait(timeout: timeout)
        connection.invalidate()
        switch result {
        case .unreachable:
            logger.notice("appEndpoint -> broker unreachable")
        case .endpoint(.some):
            logger.info("appEndpoint -> endpoint present")
        case .endpoint(.none):
            logger.info("appEndpoint -> no app registered")
        }
        return result
    }
}
