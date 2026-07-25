// AppXPCService.swift

import BattyXPCCore
import Foundation
import os

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "AppXPCService")

/// Exported over the app's anonymous XPC listener once a CLI connects
/// directly (#0271) — the broker is out of the path from here.
///
/// Must be `nonisolated final class`, not `@MainActor`, for the same reason
/// `Broker` (`BattyKit/Sources/BattyBroker/Broker.swift`) is: XPC invokes
/// exported-object methods on its own queues regardless of the class's
/// declared isolation. A `@MainActor` class's *conformance* to
/// `AppServiceProtocol` would still compile; the failure surfaces where
/// that conformance is *used*, at `newConnection.exportedObject =
/// exportedObject as any AppServiceProtocol` in
/// `AppXPCListenerDelegate.swift` (see #0269 Gotchas).
nonisolated final class AppXPCService: NSObject, AppServiceProtocol {
    /// In-flight `perform` reply closures, so `shutdown()` can answer any
    /// still-outstanding call with `XPCTerminationSignal.appTerminating`
    /// before the process quits (#0272 item 4) instead of letting the
    /// connection teardown answer for it with an indistinguishable drop.
    private let pendingRequests = PendingRequestRegistry()

    func ping(reply: @escaping @Sendable (String) -> Void) {
        let description = "pid \(ProcessInfo.processInfo.processIdentifier)"
        logger.info("ping -> \(description, privacy: .public)")
        reply(description)
    }

    func perform(_ request: Data, reply: @escaping @Sendable (Data) -> Void) {
        guard let decoded = try? JSONDecoder().decode(XPCRequest.self, from: request) else {
            logger.error("perform: failed to decode request")
            reply(Self.encode(XPCResponse(ok: false, error: "malformed request")))
            return
        }
        let requestID = pendingRequests.register(reply)
        switch decoded.verb {
        case XPCVerb.status:
            // AppStateStore.shared is MainActor-isolated; hop in rather than
            // touching it from XPC's queue. The reply block is @Sendable, so
            // calling it from inside this Task is fine — it doesn't need to
            // happen synchronously with `perform`'s own call. Replying goes
            // through `pendingRequests.resolve`, not the closure directly,
            // so a `shutdown()` racing this Task can never double-reply —
            // whichever of the two calls `resolve` first wins, the other's
            // call is a no-op (see `PendingRequestRegistry`).
            Task { @MainActor [pendingRequests] in
                let payload = AppStateStore.shared.statusPayload()
                guard let payloadData = try? JSONEncoder().encode(payload) else {
                    pendingRequests.resolve(requestID, with: Self.encode(XPCResponse(ok: false, error: "failed to encode status payload")))
                    return
                }
                logger.info("perform status -> pid=\(payload.pid, privacy: .public) windows=\(payload.windowCount, privacy: .public) sessions=\(payload.sessionCount, privacy: .public) tabs=\(payload.tabCount, privacy: .public)")
                pendingRequests.resolve(requestID, with: Self.encode(XPCResponse(ok: true, payload: payloadData)))
            }
        default:
            logger.error("perform: unknown verb \(decoded.verb, privacy: .public)")
            pendingRequests.resolve(requestID, with: Self.encode(XPCResponse(ok: false, error: "unknown verb: \(decoded.verb)")))
        }
    }

    /// Answers every in-flight `perform` call with the termination sentinel.
    /// Called from `AppXPCCoordinator.prepareForTermination()`, synchronously,
    /// before the process actually exits.
    func shutdown() {
        pendingRequests.terminateAll()
    }

    private static func encode(_ response: XPCResponse) -> Data {
        (try? JSONEncoder().encode(response)) ?? Data()
    }
}
