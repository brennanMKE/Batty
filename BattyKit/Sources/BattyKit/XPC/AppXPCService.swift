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


    // Active watch subscription tracking. Only one is registered per connection at a time,
    // replaced on each new `watch` call. Cleaned up by AppEventWatcher when the subscription
    // ID is revoked (in shutdown or on connection teardown).

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
        


    case XPCVerb.list:
            Task { @MainActor [pendingRequests] in
                let includeDimensions = decoded.payload
                    .flatMap { try? JSONDecoder().decode(ListRequest.self, from: $0) }?
                    .includeDimensions ?? false
                let payload = AppStateStore.shared.topologyPayload(includeDimensions: includeDimensions)
                guard let payloadData = try? JSONEncoder().encode(payload) else {
                    pendingRequests.resolve(requestID, with: Self.encode(XPCResponse(ok: false, error: "failed to encode topology payload")))
                    return
                }
                logger.info("perform list -> windows=\(payload.windows.count, privacy: .public)")
                pendingRequests.resolve(requestID, with: Self.encode(XPCResponse(ok: true, payload: payloadData)))
            }



        


    case XPCVerb.sessionInfo:
            Task { @MainActor [pendingRequests] in
                // A missing or undecodable request payload is treated the
                // same as an explicit `sessionID: nil` — both mean "no
                // target given, fall back to the focused session."
                let request = decoded.payload.flatMap { try? JSONDecoder().decode(SessionInfoRequest.self, from: $0) }
                let sessionID = request?.sessionID
                let includeDimensions = request?.includeDimensions ?? false
                guard let payload = AppStateStore.shared.sessionInfoPayload(sessionID: sessionID, includeDimensions: includeDimensions) else {
                    pendingRequests.resolve(requestID, with: Self.encode(XPCResponse(ok: false, error: "session not found")))
                    return
                }
                guard let payloadData = try? JSONEncoder().encode(payload) else {
                    pendingRequests.resolve(requestID, with: Self.encode(XPCResponse(ok: false, error: "failed to encode session payload")))
                    return
                }
                logger.info("perform sessionInfo -> session=\(payload.id, privacy: .public)")
                pendingRequests.resolve(requestID, with: Self.encode(XPCResponse(ok: true, payload: payloadData)))
            }



        case XPCVerb.paneSplit:
            Task { @MainActor [pendingRequests] in
                guard let payloadData = decoded.payload,
                      let request = try? JSONDecoder().decode(PaneSplitRequest.self, from: payloadData)
                else {
                    logger.error("perform paneSplit: malformed or missing request payload")
                    pendingRequests.resolve(requestID, with: Self.encode(XPCResponse(ok: false, error: "malformed pane split request")))
                    return
                }
                // A missing/nil paneID means "no explicit target" — same
                // fallback tier as sessionInfo's nil sessionID, one level
                // down (the target session's focused pane rather than the
                // focused session itself).
                guard let targetPaneID = request.paneID ?? AppStateStore.shared.focusedPaneIDFallback() else {
                    logger.error("perform paneSplit: no pane to target")
                    pendingRequests.resolve(requestID, with: Self.encode(XPCResponse(ok: false, error: "no pane to split")))
                    return
                }
                let direction = SplitDirection(rawValue: request.direction.rawValue) ?? .horizontal
                let kind = request.kind ?? .terminal
                // #0383: `--unique` find-or-create. `findUniquePane` itself
                // guards `kind != .terminal` (there is no sensible "the
                // terminal Pane" to find) — the CLI also rejects `--unique`
                // without a non-terminal `--view` client-side, but the
                // invariant lives on the function that can violate it, not
                // duplicated here.
                if request.unique == true,
                   let existingPaneID = AppStateStore.shared.findUniquePane(paneID: targetPaneID, kind: kind) {
                    guard let replyData = try? JSONEncoder().encode(PaneSplitReply(paneID: existingPaneID, created: false)) else {
                        pendingRequests.resolve(requestID, with: Self.encode(XPCResponse(ok: false, error: "failed to encode pane split reply")))
                        return
                    }
                    logger.info("perform paneSplit -> unique match, pane=\(existingPaneID, privacy: .public)")
                    pendingRequests.resolve(requestID, with: Self.encode(XPCResponse(ok: true, payload: replyData)))
                    return
                }
                // Each kind reads its own key out of the same generic bag
                // (#0304's shared-wire-shape decision) — `path` only
                // matters inside `.gitStatus`'s own construction path,
                // `pid` only inside `.processStatus`'s; neither is read
                // or validated against the other's kind here (the CLI
                // already rejected the mismatched combination client-side).
                let path = request.viewOptions?["path"]
                let processStatusPid = request.viewOptions?["pid"].flatMap { Int32($0) }
                guard let newPaneID = AppStateStore.shared.splitPane(id: targetPaneID, direction: direction, command: request.command, kind: kind, processStatusPid: processStatusPid, path: path) else {
                    logger.error("perform paneSplit: unknown pane id \(targetPaneID, privacy: .public)")
                    pendingRequests.resolve(requestID, with: Self.encode(XPCResponse(ok: false, error: "unknown pane id")))
                    return
                }
                guard let replyData = try? JSONEncoder().encode(PaneSplitReply(paneID: newPaneID, created: true)) else {
                    pendingRequests.resolve(requestID, with: Self.encode(XPCResponse(ok: false, error: "failed to encode pane split reply")))
                    return
                }
                logger.info("perform paneSplit -> pane=\(newPaneID, privacy: .public)")
                pendingRequests.resolve(requestID, with: Self.encode(XPCResponse(ok: true, payload: replyData)))
            }
        case XPCVerb.paneClose:
            Task { @MainActor [pendingRequests] in
                guard let payloadData = decoded.payload,
                      let request = try? JSONDecoder().decode(PaneCloseRequest.self, from: payloadData)
                else {
                    logger.error("perform paneClose: malformed or missing request payload")
                    pendingRequests.resolve(requestID, with: Self.encode(XPCResponse(ok: false, error: "malformed pane close request")))
                    return
                }
                guard let targetPaneID = request.paneID ?? AppStateStore.shared.focusedPaneIDFallback() else {
                    logger.error("perform paneClose: no pane to target")
                    pendingRequests.resolve(requestID, with: Self.encode(XPCResponse(ok: false, error: "no pane to close")))
                    return
                }
                switch AppStateStore.shared.closePane(id: targetPaneID) {
                case .closed:
                    guard let replyData = try? JSONEncoder().encode(PaneCloseReply()) else {
                        pendingRequests.resolve(requestID, with: Self.encode(XPCResponse(ok: false, error: "failed to encode pane close reply")))
                        return
                    }
                    logger.info("perform paneClose -> pane=\(targetPaneID, privacy: .public)")
                    pendingRequests.resolve(requestID, with: Self.encode(XPCResponse(ok: true, payload: replyData)))
                case .unknownPane:
                    logger.error("perform paneClose: unknown pane id \(targetPaneID, privacy: .public)")
                    pendingRequests.resolve(requestID, with: Self.encode(XPCResponse(ok: false, error: "unknown pane id")))
                case .needsConfirmation:
                    logger.notice("perform paneClose: refused pane=\(targetPaneID, privacy: .public) reason=needs-confirmation")
                    pendingRequests.resolve(requestID, with: Self.encode(XPCResponse(ok: false, error: "pane has a running process; close refused without confirmation")))
                case .refusedLastPane:
                    logger.notice("perform paneClose: refused pane=\(targetPaneID, privacy: .public) reason=last-pane-in-app")
                    pendingRequests.resolve(requestID, with: Self.encode(XPCResponse(ok: false, error: "refusing to close the app's last pane")))
                }
            }
        case XPCVerb.notify:
            Task { @MainActor [pendingRequests] in
                guard let payloadData = decoded.payload,
                      let request = try? JSONDecoder().decode(NotifyRequest.self, from: payloadData)
                else {
                    logger.error("perform notify: malformed or missing request payload")
                    pendingRequests.resolve(requestID, with: Self.encode(XPCResponse(ok: false, error: "malformed notify request")))
                    return
                }
                guard let targetTabID = request.tabID ?? AppStateStore.shared.focusedTabIDFallback() else {
                    logger.error("perform notify: no tab to target")
                    pendingRequests.resolve(requestID, with: Self.encode(XPCResponse(ok: false, error: "no tab to target")))
                    return
                }
                switch AppStateStore.shared.recordCLINotification(tabID: targetTabID, title: request.title, body: request.body, playSound: request.sound) {
                case .posted:
                    guard let replyData = try? JSONEncoder().encode(NotifyReply()) else {
                        pendingRequests.resolve(requestID, with: Self.encode(XPCResponse(ok: false, error: "failed to encode notify reply")))
                        return
                    }
                    logger.info("perform notify -> tab=\(targetTabID, privacy: .public)")
                    pendingRequests.resolve(requestID, with: Self.encode(XPCResponse(ok: true, payload: replyData)))
                case .unknownTab:
                    logger.error("perform notify: unknown tab id \(targetTabID, privacy: .public)")
                    pendingRequests.resolve(requestID, with: Self.encode(XPCResponse(ok: false, error: "unknown tab id")))
                }
            }
        case XPCVerb.sessionFocus:
            Task { @MainActor [pendingRequests] in
                guard let payloadData = decoded.payload,
                      let request = try? JSONDecoder().decode(SessionFocusRequest.self, from: payloadData)
                else {
                    logger.error("perform sessionFocus: malformed or missing request payload")
                    pendingRequests.resolve(requestID, with: Self.encode(XPCResponse(ok: false, error: "malformed session focus request")))
                    return
                }
                guard let targetSessionID = request.sessionID ?? AppStateStore.shared.focusedSessionIDFallback() else {
                    logger.error("perform sessionFocus: no session to target")
                    pendingRequests.resolve(requestID, with: Self.encode(XPCResponse(ok: false, error: "no session to target")))
                    return
                }
                switch AppStateStore.shared.focusSessionForXPC(id: targetSessionID) {
                case .focused:
                    guard let replyData = try? JSONEncoder().encode(SessionFocusReply()) else {
                        pendingRequests.resolve(requestID, with: Self.encode(XPCResponse(ok: false, error: "failed to encode session focus reply")))
                        return
                    }
                    logger.info("perform sessionFocus -> session=\(targetSessionID, privacy: .public)")
                    pendingRequests.resolve(requestID, with: Self.encode(XPCResponse(ok: true, payload: replyData)))
                case .unknownSession:
                    logger.error("perform sessionFocus: unknown session id \(targetSessionID, privacy: .public)")
                    pendingRequests.resolve(requestID, with: Self.encode(XPCResponse(ok: false, error: "unknown session id")))
                }
            }
        case XPCVerb.paneFocus:
            Task { @MainActor [pendingRequests] in
                guard let payloadData = decoded.payload,
                      let request = try? JSONDecoder().decode(PaneFocusRequest.self, from: payloadData)
                else {
                    logger.error("perform paneFocus: malformed or missing request payload")
                    pendingRequests.resolve(requestID, with: Self.encode(XPCResponse(ok: false, error: "malformed pane focus request")))
                    return
                }
                guard let targetPaneID = request.paneID ?? AppStateStore.shared.focusedPaneIDFallback() else {
                    logger.error("perform paneFocus: no pane to target")
                    pendingRequests.resolve(requestID, with: Self.encode(XPCResponse(ok: false, error: "no pane to target")))
                    return
                }
                switch AppStateStore.shared.focusPaneForXPC(id: targetPaneID) {
                case .focused:
                    guard let replyData = try? JSONEncoder().encode(PaneFocusReply()) else {
                        pendingRequests.resolve(requestID, with: Self.encode(XPCResponse(ok: false, error: "failed to encode pane focus reply")))
                        return
                    }
                    logger.info("perform paneFocus -> pane=\(targetPaneID, privacy: .public)")
                    pendingRequests.resolve(requestID, with: Self.encode(XPCResponse(ok: true, payload: replyData)))
                case .unknownPane:
                    logger.error("perform paneFocus: unknown pane id \(targetPaneID, privacy: .public)")
                    pendingRequests.resolve(requestID, with: Self.encode(XPCResponse(ok: false, error: "unknown pane id")))
                }
            }
        case XPCVerb.tabFocus:
            Task { @MainActor [pendingRequests] in
                guard let payloadData = decoded.payload,
                      let request = try? JSONDecoder().decode(TabFocusRequest.self, from: payloadData)
                else {
                    logger.error("perform tabFocus: malformed or missing request payload")
                    pendingRequests.resolve(requestID, with: Self.encode(XPCResponse(ok: false, error: "malformed tab focus request")))
                    return
                }
                guard let targetTabID = request.tabID ?? AppStateStore.shared.focusedTabIDFallback() else {
                    logger.error("perform tabFocus: no tab to target")
                    pendingRequests.resolve(requestID, with: Self.encode(XPCResponse(ok: false, error: "no tab to target")))
                    return
                }
                switch AppStateStore.shared.focusTabForXPC(id: targetTabID) {
                case .focused:
                    guard let replyData = try? JSONEncoder().encode(TabFocusReply()) else {
                        pendingRequests.resolve(requestID, with: Self.encode(XPCResponse(ok: false, error: "failed to encode tab focus reply")))
                        return
                    }
                    logger.info("perform tabFocus -> tab=\(targetTabID, privacy: .public)")
                    pendingRequests.resolve(requestID, with: Self.encode(XPCResponse(ok: true, payload: replyData)))
                case .unknownTab:
                    logger.error("perform tabFocus: unknown tab id \(targetTabID, privacy: .public)")
                    pendingRequests.resolve(requestID, with: Self.encode(XPCResponse(ok: false, error: "unknown tab id")))
                }
            }
        case XPCVerb.sessionClose:
            Task { @MainActor [pendingRequests] in
                guard let payloadData = decoded.payload,
                      let request = try? JSONDecoder().decode(SessionCloseRequest.self, from: payloadData)
                else {
                    logger.error("perform sessionClose: malformed or missing request payload")
                    pendingRequests.resolve(requestID, with: Self.encode(XPCResponse(ok: false, error: "malformed session close request")))
                    return
                }
                guard let targetSessionID = request.sessionID ?? AppStateStore.shared.focusedSessionIDFallback() else {
                    logger.error("perform sessionClose: no session to target")
                    pendingRequests.resolve(requestID, with: Self.encode(XPCResponse(ok: false, error: "no session to target")))
                    return
                }
                switch AppStateStore.shared.closeSessionForXPC(id: targetSessionID) {
                case .closed:
                    guard let replyData = try? JSONEncoder().encode(SessionCloseReply()) else {
                        pendingRequests.resolve(requestID, with: Self.encode(XPCResponse(ok: false, error: "failed to encode session close reply")))
                        return
                    }
                    logger.info("perform sessionClose -> session=\(targetSessionID, privacy: .public)")
                    pendingRequests.resolve(requestID, with: Self.encode(XPCResponse(ok: true, payload: replyData)))
                case .unknownSession:
                    logger.error("perform sessionClose: unknown session id \(targetSessionID, privacy: .public)")
                    pendingRequests.resolve(requestID, with: Self.encode(XPCResponse(ok: false, error: "unknown session id")))
                case .needsConfirmation:
                    logger.notice("perform sessionClose: refused session=\(targetSessionID, privacy: .public) reason=needs-confirmation")
                    pendingRequests.resolve(requestID, with: Self.encode(XPCResponse(ok: false, error: "session has a running process; close refused without confirmation")))
                case .refusedLastSession:
                    logger.notice("perform sessionClose: refused session=\(targetSessionID, privacy: .public) reason=last-session-in-app")
                    pendingRequests.resolve(requestID, with: Self.encode(XPCResponse(ok: false, error: "refusing to close the app's last session")))
                }
            }
        case XPCVerb.paneHide:
            Task { @MainActor [pendingRequests] in
                guard let payloadData = decoded.payload,
                      let request = try? JSONDecoder().decode(PaneHideRequest.self, from: payloadData)
                else {
                    logger.error("perform paneHide: malformed or missing request payload")
                    pendingRequests.resolve(requestID, with: Self.encode(XPCResponse(ok: false, error: "malformed pane hide request")))
                    return
                }
                guard let targetPaneID = request.paneID ?? AppStateStore.shared.focusedPaneIDFallback() else {
                    logger.error("perform paneHide: no pane to target")
                    pendingRequests.resolve(requestID, with: Self.encode(XPCResponse(ok: false, error: "no pane to target")))
                    return
                }
                switch AppStateStore.shared.hidePaneForXPC(id: targetPaneID) {
                case .hidden, .alreadyHidden:
                    guard let replyData = try? JSONEncoder().encode(PaneHideReply()) else {
                        pendingRequests.resolve(requestID, with: Self.encode(XPCResponse(ok: false, error: "failed to encode pane hide reply")))
                        return
                    }
                    logger.info("perform paneHide -> pane=\(targetPaneID, privacy: .public)")
                    pendingRequests.resolve(requestID, with: Self.encode(XPCResponse(ok: true, payload: replyData)))
                case .unknownPane:
                    logger.error("perform paneHide: unknown pane id \(targetPaneID, privacy: .public)")
                    pendingRequests.resolve(requestID, with: Self.encode(XPCResponse(ok: false, error: "unknown pane id")))
                case .refusedLastVisiblePane:
                    logger.notice("perform paneHide: refused pane=\(targetPaneID, privacy: .public) reason=last-visible-pane")
                    pendingRequests.resolve(requestID, with: Self.encode(XPCResponse(ok: false, error: "refusing to hide the session's last visible pane")))
                }
            }
        case XPCVerb.paneShow:
            Task { @MainActor [pendingRequests] in
                guard let payloadData = decoded.payload,
                      let request = try? JSONDecoder().decode(PaneShowRequest.self, from: payloadData)
                else {
                    logger.error("perform paneShow: malformed or missing request payload")
                    pendingRequests.resolve(requestID, with: Self.encode(XPCResponse(ok: false, error: "malformed pane show request")))
                    return
                }
                switch AppStateStore.shared.showPaneForXPC(id: request.paneID) {
                case .shown, .alreadyVisible:
                    guard let replyData = try? JSONEncoder().encode(PaneShowReply()) else {
                        pendingRequests.resolve(requestID, with: Self.encode(XPCResponse(ok: false, error: "failed to encode pane show reply")))
                        return
                    }
                    logger.info("perform paneShow -> pane=\(request.paneID, privacy: .public)")
                    pendingRequests.resolve(requestID, with: Self.encode(XPCResponse(ok: true, payload: replyData)))
                case .unknownPane:
                    logger.error("perform paneShow: unknown pane id \(request.paneID, privacy: .public)")
                    pendingRequests.resolve(requestID, with: Self.encode(XPCResponse(ok: false, error: "unknown pane id")))
                }
            }

            case XPCVerb.watch:
            watch(request, reply: reply)

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

    /// #0145: long-lived streaming verb. The CLI sends a `WatchSubscriptionRequest`
    /// JSON-encoded as `Data`; we decode it, register a reply block with the shared
    /// event watcher (`AppEventWatcher`), and keep the connection alive until shutdown.
    nonisolated func watch(_ request: Data, reply: @escaping @Sendable (Data) -> Void) {
        guard let subscriptionRequest = try? JSONDecoder().decode(WatchSubscriptionRequest.self, from: request) else {
            logger.error("watch: failed to decode subscription request")
            reply(Self.encode(XPCResponse(ok: false, error: "malformed watch subscription request")))
            return
        }

        let events = subscriptionRequest.events ?? WatchEventType.allNames

        // Wrap reply block so events travel over XPC.
        let wrappedBlock: @Sendable (WatchEventPayload) -> Void = { eventData in
            if let data = try? JSONEncoder().encode(eventData) {
                reply(data)
            } else {
                logger.error("watch: failed to encode event payload")
            }
        }

        Task { @MainActor [pendingRequests] in
            let subID = AppEventWatcher.shared.subscribe(events: events, replyBlock: wrappedBlock)
            logger.info("watch subscription started id=\(subID, privacy: .public)")

            if subscriptionRequest.sendTopoSnapshot {
                let snapshot = AppStateStore.shared.topologyPayload(includeDimensions: false)

                guard let firstSession = snapshot.windows.first?.sessions.first else {
                    return
                }

                let snapshotEvent = WatchEventPayload(
                    type: "topology_snapshot",
                    sessionID: firstSession.id,
                    targetPaneID: nil,
                    tabID: nil
                )

                guard let data = try? JSONEncoder().encode(snapshotEvent) else { return }
                reply(data)

                logger.info("watch: topology snapshot sent for session \(firstSession.id, privacy: .public)")
            }

            _ = pendingRequests.register { _ in }
        }

        return
    }

    private static func encode(_ response: XPCResponse) -> Data {
        (try? JSONEncoder().encode(response)) ?? Data()
    }

    // Instance logger. Line 7 of the file declares `nonisolated private let logger` for the same
    // category. Both properties are reachable from unrelated call sites in the same file.
}
