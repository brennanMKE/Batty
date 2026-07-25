// BrokerPingClient.swift

import BattyXPCCore
import Foundation

/// Synchronous XPC round trip to the broker's `brokerPing`, for
/// `batty ping` — "the most valuable diagnostic in this repo" per
/// `docs/xpc/xpc-cli-architecture.md`: it reaches launchd's on-demand
/// broker with the app never launched, so success means launchd owns the
/// Mach service name regardless of anything app-side.
///
/// `ParsableCommand.run()` is synchronous, so this blocks the calling
/// thread on a semaphore rather than using Swift concurrency — the standard
/// shape for a one-shot XPC call from a CLI's `run()`.
nonisolated enum BrokerPingClient {
    struct Outcome: Sendable {
        let reachable: Bool
        let message: String?
    }

    static func ping(timeout: TimeInterval) -> Outcome {
        let once = XPCOnce(defaultValue: Outcome(reachable: false, message: nil))
        let connection = NSXPCConnection(machServiceName: ServiceNames.broker)
        connection.remoteObjectInterface = XPCInterfaces.broker
        connection.interruptionHandler = { @Sendable in once.finish(Outcome(reachable: false, message: nil)) }
        connection.invalidationHandler = { @Sendable in once.finish(Outcome(reachable: false, message: nil)) }
        connection.resume()

        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ @Sendable _ in
            once.finish(Outcome(reachable: false, message: nil))
        }) as? BrokerProtocol else {
            connection.invalidate()
            return Outcome(reachable: false, message: nil)
        }

        proxy.brokerPing { @Sendable message in
            once.finish(Outcome(reachable: true, message: message))
        }

        let outcome = once.wait(timeout: timeout)
        connection.invalidate()
        return outcome
    }
}
