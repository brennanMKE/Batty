// AppServiceClient.swift

import BattyXPCCore
import Foundation
import os

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "AppServiceClient")

/// Step 5 of the connect dance: a direct `NSXPCConnection` to the app's
/// endpoint (the broker is no longer involved), and the one-shot
/// request/reply call the whole track was built for.
///
/// One connect/call/wait dance (`perform(verb:requestPayload:...)`) is
/// shared by every verb (`status` #0271; `list`/`sessionInfo` #0274) —
/// only the verb string, optional request payload, and decoded reply type
/// differ. Extracted from #0271's original `status`-only implementation
/// when #0274 added two more verbs with an identical shape.
nonisolated enum AppServiceClient {
    enum Outcome<Payload: Sendable>: Sendable {
        case success(Payload)
        /// The connection to the app itself failed or timed out — the
        /// endpoint the broker handed back is stale (app died between
        /// registering and this connection, or mid-poll).
        case unreachable
        /// The app replied, but either declined the request or the reply
        /// couldn't be decoded.
        case requestFailed(String)
        /// The app replied with `XPCTerminationSignal.appTerminating`
        /// before quitting (#0272 item 4) — distinguished from `unreachable`
        /// (a raw connection drop) and `requestFailed` (an ordinary
        /// declined request) so the CLI can report `XPCExitCode
        /// .sessionTerminated` (5) rather than either of those.
        case appTerminated
    }

    static func status(endpoint: NSXPCListenerEndpoint, timeout: TimeInterval) -> Outcome<StatusPayload> {
        let outcome: Outcome<StatusPayload> = perform(verb: XPCVerb.status, requestPayload: nil, endpoint: endpoint, timeout: timeout, logLabel: "status")
        if case .success(let payload) = outcome {
            logger.info("status -> pid=\(payload.pid, privacy: .public) windows=\(payload.windowCount, privacy: .public) sessions=\(payload.sessionCount, privacy: .public)")
        }
        return outcome
    }


    /// #0274. No request payload — `list` always reports the full topology;
    /// the CLI's `--json`/plain-text filtering happens client-side.
    static func list(endpoint: NSXPCListenerEndpoint, includeDimensions: Bool, timeout: TimeInterval) -> Outcome<TopologyPayload> {
        let requestPayload = try? JSONEncoder().encode(ListRequest(includeDimensions: includeDimensions))
        let outcome: Outcome<TopologyPayload> = perform(verb: XPCVerb.list, requestPayload: requestPayload, endpoint: endpoint, timeout: timeout, logLabel: "list")
        // Counts only, never paths/titles — matches #0271's reviewed
        // "no user paths" logging discipline; topology payloads carry cwds
        // and titles that status's counts-only payload never did.
        if case .success(let payload) = outcome {
            logger.info("list -> windows=\(payload.windows.count, privacy: .public) sessions=\(payload.windows.reduce(0) { $0 + $1.sessions.count }, privacy: .public)")
        }
        return outcome
    }

    /// #0274. `sessionID == nil` asks the app to resolve the focused
    /// session (see `AppStateStore.sessionInfoPayload(sessionID:)`).
    static func sessionInfo(endpoint: NSXPCListenerEndpoint, sessionID: UUID?, includeDimensions: Bool, timeout: TimeInterval) -> Outcome<TopologySessionPayload> {
        let requestPayload = try? JSONEncoder().encode(SessionInfoRequest(sessionID: sessionID, includeDimensions: includeDimensions))
        let outcome: Outcome<TopologySessionPayload> = perform(verb: XPCVerb.sessionInfo, requestPayload: requestPayload, endpoint: endpoint, timeout: timeout, logLabel: "sessionInfo")
        // The session id alone, not its name/path — same "no user paths" rule.
        if case .success(let payload) = outcome {
            logger.info("sessionInfo -> session=\(payload.id, privacy: .public) panes=\(payload.allPanes.count, privacy: .public)")
        }
        return outcome
    }

    /// #0282. The first *mutating* call this dance drives — the app either
    /// splits the target pane and replies with its new id, or reports a
    /// failure (unknown/stale `paneID`, no pane to target) via
    /// `.requestFailed`, which the CLI turns into exit `4`.
    static func paneSplit(
        endpoint: NSXPCListenerEndpoint,
        paneID: UUID?,
        direction: TopologySplitDirection,
        command: String?,
        kind: PaneContentKind? = nil,
        timeout: TimeInterval
    ) -> Outcome<PaneSplitReply> {
        let requestPayload = try? JSONEncoder().encode(PaneSplitRequest(paneID: paneID, direction: direction, command: command, kind: kind))
        let outcome: Outcome<PaneSplitReply> = perform(verb: XPCVerb.paneSplit, requestPayload: requestPayload, endpoint: endpoint, timeout: timeout, logLabel: "paneSplit")
        if case .success(let payload) = outcome {
            logger.info("paneSplit -> pane=\(payload.paneID, privacy: .public)")
        }
        return outcome
    }

    /// #0283. Reuses #0282's mutating-verb dance. The app either ends every
    /// Tab's Terminal Session in the target pane and removes it from the
    /// split tree, or reports a failure (unknown/stale `paneID`, a Tab
    /// needing confirmation XPC has no UI to give, or a refusal to close
    /// the app's last remaining pane) via `.requestFailed`, which the CLI
    /// turns into exit `4`.
    static func paneClose(
        endpoint: NSXPCListenerEndpoint,
        paneID: UUID?,
        timeout: TimeInterval
    ) -> Outcome<PaneCloseReply> {
        let requestPayload = try? JSONEncoder().encode(PaneCloseRequest(paneID: paneID))
        let outcome: Outcome<PaneCloseReply> = perform(verb: XPCVerb.paneClose, requestPayload: requestPayload, endpoint: endpoint, timeout: timeout, logLabel: "paneClose")
        if case .success = outcome {
            logger.info("paneClose -> pane=\(paneID?.uuidString ?? "<focused>", privacy: .public)")
        }
        return outcome
    }

    /// #0284. Reuses #0282/#0283's mutating-verb dance. The app either
    /// posts a `BellFeedEntry` attributed to the target tab, or reports a
    /// failure (unknown/stale `tabID`, no tab to target) via
    /// `.requestFailed`, which the CLI turns into exit `4` — the reason
    /// `notify` moved to XPC rather than staying on the fire-and-forget
    /// `batty://` scheme.
    static func notify(
        endpoint: NSXPCListenerEndpoint,
        tabID: UUID?,
        title: String,
        body: String?,
        sound: Bool,
        timeout: TimeInterval
    ) -> Outcome<NotifyReply> {
        let requestPayload = try? JSONEncoder().encode(NotifyRequest(tabID: tabID, title: title, body: body, sound: sound))
        let outcome: Outcome<NotifyReply> = perform(verb: XPCVerb.notify, requestPayload: requestPayload, endpoint: endpoint, timeout: timeout, logLabel: "notify")
        if case .success = outcome {
            logger.info("notify -> tab=\(tabID?.uuidString ?? "<focused>", privacy: .public)")
        }
        return outcome
    }

    private static func perform<Payload: Decodable & Sendable>(
        verb: String,
        requestPayload: Data?,
        endpoint: NSXPCListenerEndpoint,
        timeout: TimeInterval,
        logLabel: String
    ) -> Outcome<Payload> {
        let once = XPCOnce<Outcome<Payload>>(defaultValue: .unreachable)
        let connection = NSXPCConnection(listenerEndpoint: endpoint)
        connection.remoteObjectInterface = XPCInterfaces.appService
        // #0278: `endpoint` is data the broker handed back, not something
        // launchd vouches for — validate the peer here even though the
        // broker connection that fetched it was already validated.
        OutgoingCodeSigningEnforcement.apply(to: connection, context: "CLI→app")
        connection.interruptionHandler = { @Sendable in
            logger.notice("\(logLabel, privacy: .public): app connection interrupted")
            once.finish(.unreachable)
        }
        connection.invalidationHandler = { @Sendable in
            logger.notice("\(logLabel, privacy: .public): app connection invalidated")
            once.finish(.unreachable)
        }
        connection.resume()

        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ @Sendable error in
            logger.error("\(logLabel, privacy: .public): app unreachable — \(error.localizedDescription, privacy: .public)")
            once.finish(.unreachable)
        }) as? AppServiceProtocol else {
            logger.error("\(logLabel, privacy: .public): failed to obtain app proxy")
            connection.invalidate()
            return .unreachable
        }

        guard let requestData = try? JSONEncoder().encode(XPCRequest(verb: verb, payload: requestPayload)) else {
            logger.error("\(logLabel, privacy: .public): failed to encode request")
            connection.invalidate()
            return .requestFailed("failed to encode request")
        }

        proxy.perform(requestData) { @Sendable data in
            guard let response = try? JSONDecoder().decode(XPCResponse.self, from: data) else {
                logger.error("\(logLabel, privacy: .public): malformed response")
                once.finish(.requestFailed("malformed response"))
                return
            }
            guard response.ok, let payloadData = response.payload,
                  let payload = try? JSONDecoder().decode(Payload.self, from: payloadData)
            else {
                if response.error == XPCTerminationSignal.appTerminating {
                    logger.notice("\(logLabel, privacy: .public): app terminating mid-request")
                    once.finish(.appTerminated)
                } else {
                    logger.error("\(logLabel, privacy: .public): app reported failure — \(response.error ?? "<none>", privacy: .public)")
                    once.finish(.requestFailed(response.error ?? "app reported failure"))
                }
                return
            }
            once.finish(.success(payload))
        }

        let outcome = once.wait(timeout: timeout)
        connection.invalidate()
        return outcome
    }
}
