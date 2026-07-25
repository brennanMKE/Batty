// AppServiceClient.swift

import BattyXPCCore
import Foundation
import os

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "AppServiceClient")

/// Step 5 of the connect dance: a direct `NSXPCConnection` to the app's
/// endpoint (the broker is no longer involved), and the one-shot
/// request/reply call the whole track was built for.
nonisolated enum AppServiceClient {
    enum Outcome: Sendable {
        case success(StatusPayload)
        /// The connection to the app itself failed or timed out — the
        /// endpoint the broker handed back is stale (app died between
        /// registering and this connection, or mid-poll).
        case unreachable
        /// The app replied, but either declined the request or the reply
        /// couldn't be decoded.
        case requestFailed(String)
    }

    static func status(endpoint: NSXPCListenerEndpoint, timeout: TimeInterval) -> Outcome {
        let once = XPCOnce<Outcome>(defaultValue: .unreachable)
        let connection = NSXPCConnection(listenerEndpoint: endpoint)
        connection.remoteObjectInterface = XPCInterfaces.appService
        connection.interruptionHandler = { @Sendable in
            logger.notice("status: app connection interrupted")
            once.finish(.unreachable)
        }
        connection.invalidationHandler = { @Sendable in
            logger.notice("status: app connection invalidated")
            once.finish(.unreachable)
        }
        connection.resume()

        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ @Sendable error in
            logger.error("status: app unreachable — \(error.localizedDescription, privacy: .public)")
            once.finish(.unreachable)
        }) as? AppServiceProtocol else {
            logger.error("status: failed to obtain app proxy")
            connection.invalidate()
            return .unreachable
        }

        guard let requestData = try? JSONEncoder().encode(XPCRequest(verb: XPCVerb.status)) else {
            logger.error("status: failed to encode request")
            connection.invalidate()
            return .requestFailed("failed to encode request")
        }

        proxy.perform(requestData) { @Sendable data in
            guard let response = try? JSONDecoder().decode(XPCResponse.self, from: data) else {
                logger.error("status: malformed response")
                once.finish(.requestFailed("malformed response"))
                return
            }
            guard response.ok, let payloadData = response.payload,
                  let payload = try? JSONDecoder().decode(StatusPayload.self, from: payloadData)
            else {
                logger.error("status: app reported failure — \(response.error ?? "<none>", privacy: .public)")
                once.finish(.requestFailed(response.error ?? "app reported failure"))
                return
            }
            once.finish(.success(payload))
        }

        let outcome = once.wait(timeout: timeout)
        connection.invalidate()
        if case .success(let payload) = outcome {
            logger.info("status -> pid=\(payload.pid, privacy: .public) windows=\(payload.windowCount, privacy: .public) sessions=\(payload.sessionCount, privacy: .public)")
        }
        return outcome
    }
}
