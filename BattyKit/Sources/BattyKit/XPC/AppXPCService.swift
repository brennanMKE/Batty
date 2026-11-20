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

    /// The store the Project verbs act on. Every older verb reads
    /// `AppStateStore.shared` directly; the Project verbs go through this so
    /// a test can supply its own store.
    private let storeProvider: @MainActor @Sendable () -> AppStateStore
    private let clock: any SchedulingClock
    /// Ends a `--wait` when its CLI's connection goes away.
    private let connectionRegistry: AppXPCConnectionRegistry?
    private let resolvedShell: @MainActor @Sendable () -> String
    private let commandWaitTab: @MainActor @Sendable (TabRuntime) -> any CommandWaitTab

    init(
        store: @escaping @MainActor @Sendable () -> AppStateStore = { AppStateStore.shared },
        clock: any SchedulingClock = SystemClock(),
        connectionRegistry: AppXPCConnectionRegistry? = nil,
        resolvedShell: @escaping @MainActor @Sendable () -> String = { SettingsPreference.resolvedShell() },
        commandWaitTab: @escaping @MainActor @Sendable (TabRuntime) -> any CommandWaitTab = { TabRuntimeCommandWaitTab(tab: $0) }
    ) {
        self.storeProvider = store
        self.clock = clock
        self.connectionRegistry = connectionRegistry
        self.resolvedShell = resolvedShell
        self.commandWaitTab = commandWaitTab
        super.init()
    }

    // Active watch subscription tracking. Only one is registered per connection at a time,
    // replaced on each new `watch` call. Cleaned up by AppEventWatcher when the subscription
    // ID is revoked (in shutdown or on connection teardown).

    func ping(reply: @escaping @Sendable (String) -> Void) {
        let description = "pid \(ProcessInfo.processInfo.processIdentifier)"
        logger.info("ping -> \(description, privacy: .public)")
        reply(description)
    }

    func perform(_ request: Data, reply: @escaping @Sendable (Data) -> Void) {
        perform(request, connectionID: NSXPCConnection.current().map(ObjectIdentifier.init), reply: reply)
    }

    func perform(_ request: Data, connectionID: ObjectIdentifier?, reply: @escaping @Sendable (Data) -> Void) {
        guard let decoded = try? JSONDecoder().decode(XPCRequest.self, from: request) else {
            logger.error("perform: failed to decode request")
            reply(Self.encode(XPCResponse(ok: false, error: "malformed request")))
            return
        }
        let requestID = pendingRequests.register(reply)
        if Self.isCommandWait(decoded) {
            startCommandWait(decoded, requestID: requestID, connectionID: connectionID)
            return
        }
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
            Task { @MainActor [pendingRequests, storeProvider] in
                let store = storeProvider()
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
                guard let targetPaneID = request.paneID ?? store.focusedPaneIDFallback() else {
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
                   let existingPaneID = store.findUniquePane(paneID: targetPaneID, kind: kind) {
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
                guard let newPaneID = store.splitPane(id: targetPaneID, direction: direction, command: request.command, kind: kind, processStatusPid: processStatusPid, path: path) else {
                    logger.error("perform paneSplit: unknown pane id \(targetPaneID, privacy: .public)")
                    pendingRequests.resolve(requestID, with: Self.encode(XPCResponse(ok: false, error: "unknown pane id")))
                    return
                }
                guard let replyData = try? JSONEncoder().encode(PaneSplitReply(paneID: newPaneID, created: true, tabID: kind == .terminal ? store.terminalPane(id: newPaneID)?.tabs.first?.id : nil)) else {
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
        case XPCVerb.tabNew:
            Task { @MainActor [pendingRequests, storeProvider] in
                let store = storeProvider()
                guard let payloadData = decoded.payload,
                      let request = try? JSONDecoder().decode(TabNewRequest.self, from: payloadData)
                else {
                    logger.error("perform tabNew: malformed or missing request payload")
                    pendingRequests.resolve(requestID, with: Self.encode(XPCResponse(ok: false, error: "malformed tab new request")))
                    return
                }
                guard let targetPaneID = request.paneID ?? store.focusedPaneIDFallback() else {
                    logger.error("perform tabNew: no pane to target")
                    pendingRequests.resolve(requestID, with: Self.encode(XPCResponse(ok: false, error: "no pane to target")))
                    return
                }
                let outcome = store.newTabForXPC(
                    paneID: targetPaneID,
                    sourceTabID: request.sourceTabID,
                    command: request.command,
                    workingDirectory: request.workingDirectory,
                    background: request.background ?? false
                )
                switch outcome {
                case let .created(sessionID, paneID, tabID):
                    guard let replyData = try? JSONEncoder().encode(TabNewReply(sessionID: sessionID, paneID: paneID, tabID: tabID)) else {
                        pendingRequests.resolve(requestID, with: Self.encode(XPCResponse(ok: false, error: "failed to encode tab new reply")))
                        return
                    }
                    logger.info("perform tabNew -> pane=\(paneID, privacy: .public) tab=\(tabID, privacy: .public)")
                    pendingRequests.resolve(requestID, with: Self.encode(XPCResponse(ok: true, payload: replyData)))
                case .unknownPane:
                    logger.error("perform tabNew: unknown pane id \(targetPaneID, privacy: .public)")
                    pendingRequests.resolve(requestID, with: Self.encode(XPCResponse(ok: false, error: "unknown pane id")))
                case .notTerminal:
                    logger.error("perform tabNew: pane \(targetPaneID, privacy: .public) is not a terminal pane")
                    pendingRequests.resolve(requestID, with: Self.encode(XPCResponse(ok: false, error: "pane is not a terminal pane")))
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
        case XPCVerb.sessionRemind:
            Task { @MainActor [pendingRequests] in
                guard let payloadData = decoded.payload,
                      let request = try? JSONDecoder().decode(SessionRemindRequest.self, from: payloadData)
                else {
                    logger.error("perform sessionRemind: malformed or missing request payload")
                    pendingRequests.resolve(requestID, with: Self.encode(XPCResponse(ok: false, error: "malformed session remind request")))
                    return
                }
                let reply: SessionRemindReply
                switch AppStateStore.shared.remindSessionForXPC(request) {
                case .set(let reminder, let sessionID):
                    reply = SessionRemindReply(sessionID: sessionID, reminder: reminder.topologyPayload(calendar: AppStateStore.shared.reminderScheduler.calendar))
                case .cancelled(let sessionID):
                    reply = SessionRemindReply(sessionID: sessionID, reminder: nil)
                case .unknownSession:
                    logger.error("perform sessionRemind: unknown session id")
                    pendingRequests.resolve(requestID, with: Self.encode(XPCResponse(ok: false, error: "unknown session id")))
                    return
                case .noSessionToTarget:
                    logger.error("perform sessionRemind: no session to target")
                    pendingRequests.resolve(requestID, with: Self.encode(XPCResponse(ok: false, error: "no session to target")))
                    return
                case .invalidSpec:
                    logger.error("perform sessionRemind: reminder time out of range")
                    pendingRequests.resolve(requestID, with: Self.encode(XPCResponse(ok: false, error: "reminder time out of range")))
                    return
                }
                guard let replyData = try? JSONEncoder().encode(reply) else {
                    pendingRequests.resolve(requestID, with: Self.encode(XPCResponse(ok: false, error: "failed to encode session remind reply")))
                    return
                }
                logger.info("perform sessionRemind -> session=\(reply.sessionID, privacy: .public) set=\(reply.reminder != nil, privacy: .public)")
                pendingRequests.resolve(requestID, with: Self.encode(XPCResponse(ok: true, payload: replyData)))
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

        case XPCVerb.projectList:
            Task { @MainActor [pendingRequests, storeProvider] in
                let store = storeProvider()
                if let problem = store.projectFileProblemForXPC() {
                    logger.error("perform projectList: \(problem, privacy: .public)")
                    pendingRequests.resolve(requestID, with: Self.encode(XPCResponse(ok: false, error: problem)))
                    return
                }
                let reply = store.projectListReplyForXPC()
                guard let replyData = try? JSONEncoder().encode(reply)
                else {
                    pendingRequests.resolve(requestID, with: Self.encode(XPCResponse(ok: false, error: "failed to build project list")))
                    return
                }
                logger.info("perform projectList -> projects=\(reply.projects.count, privacy: .public)")
                pendingRequests.resolve(requestID, with: Self.encode(XPCResponse(ok: true, payload: replyData)))
            }
        case XPCVerb.projectOpen:
            Task { @MainActor [pendingRequests, storeProvider, clock] in
                let store = storeProvider()
                guard let payloadData = decoded.payload,
                      let request = try? JSONDecoder().decode(ProjectOpenRequest.self, from: payloadData)
                else {
                    logger.error("perform projectOpen: malformed or missing request payload")
                    pendingRequests.resolve(requestID, with: Self.encode(XPCResponse(ok: false, error: "malformed project open request")))
                    return
                }
                let waiter = ProjectOpenWaiter()
                let opened = store.openProjectForXPC(name: request.name, openNew: request.openNew) { outcome in
                    waiter.timeoutTask?.cancel()
                    switch outcome {
                    case .opened(let reply):
                        guard let replyData = try? JSONEncoder().encode(reply) else {
                            pendingRequests.resolve(requestID, with: Self.encode(XPCResponse(ok: false, error: "failed to encode project open reply")))
                            return
                        }
                        logger.info("perform projectOpen -> session=\(reply.sessionID?.uuidString ?? "<none>", privacy: .public) created=\(reply.created, privacy: .public)")
                        pendingRequests.resolve(requestID, with: Self.encode(XPCResponse(ok: true, payload: replyData)))
                    case .failed(let message):
                        logger.error("perform projectOpen: \(message, privacy: .public)")
                        pendingRequests.resolve(requestID, with: Self.encode(XPCResponse(ok: false, error: message)))
                    }
                }
                guard let opened, let trustRequestID = opened.trustRequestID else { return }
                // The startup-command sheet is waiting for the user. Reply
                // once they answer. If they never do, withdraw the sheet at
                // the bound so a later answer cannot open a Project for a
                // caller that has already been told it did not open. A CLI
                // that is killed while waiting leaves the sheet up until the
                // same bound; the user's consent still applies to whatever
                // they answer. Resolving first means the cancellation's own
                // completion finds the request already answered.
                let name = opened.projectName
                waiter.timeoutTask = Task { @MainActor in
                    await clock.sleep(for: .seconds(ProjectOpenRequest.confirmationBoundSeconds))
                    guard !Task.isCancelled else { return }
                    let reply = ProjectOpenReply(status: .awaitingConfirmation, name: name, sessionID: nil, paneID: nil, created: false)
                    if let replyData = try? JSONEncoder().encode(reply) {
                        logger.notice("perform projectOpen: trust sheet unanswered; withdrawing it")
                        pendingRequests.resolve(requestID, with: Self.encode(XPCResponse(ok: true, payload: replyData)))
                    }
                    store.cancelStartupTrust(requestID: trustRequestID)
                }
            }

        case XPCVerb.serverStart, XPCVerb.serverShare, XPCVerb.serverList, XPCVerb.serverUnshare, XPCVerb.serverStop, XPCVerb.serverRestart, XPCVerb.serverServe, XPCVerb.serverTailnet:
            Task { @MainActor [pendingRequests, storeProvider, clock] in
                let response = await Self.serverResponse(verb: decoded.verb, payload: decoded.payload, store: storeProvider(), clock: clock)
                pendingRequests.resolve(requestID, with: Self.encode(response))
            }

        default:
            logger.error("perform: unknown verb \(decoded.verb, privacy: .public)")
            pendingRequests.resolve(requestID, with: Self.unknownVerbResponse(decoded.verb))
        }
    }

    // MARK: - Command wait (#0668)

    private struct WaitProbe: Decodable { let wait: Bool? }

    static func isCommandWait(_ request: XPCRequest) -> Bool {
        guard request.verb == XPCVerb.paneSplit || request.verb == XPCVerb.tabNew,
              let payload = request.payload,
              let probe = try? JSONDecoder().decode(WaitProbe.self, from: payload)
        else { return false }
        return probe.wait == true
    }

    /// Runs the wait in a Task that a disconnect of the requesting CLI
    /// cancels; the command itself keeps running.
    private func startCommandWait(_ decoded: XPCRequest, requestID: UUID, connectionID: ObjectIdentifier?) {
        let task = Task { @MainActor [pendingRequests, storeProvider, clock, resolvedShell, commandWaitTab] in
            let response = await Self.commandWaitResponse(
                verb: decoded.verb,
                payload: decoded.payload,
                store: storeProvider(),
                shell: resolvedShell(),
                clock: clock,
                makeTab: commandWaitTab
            )
            pendingRequests.resolve(requestID, with: Self.encode(response))
        }
        guard let connectionID, let registry = connectionRegistry else { return }
        let token = registry.onUnregister(id: connectionID) { task.cancel() }
        guard let token else { return }
        Task {
            await task.value
            registry.removeUnregisterHandler(id: connectionID, token: token)
        }
    }

    /// Why a `--wait` request is refused before anything is created, or nil.
    @MainActor
    static func commandWaitRefusal(command: String?, kind: PaneContentKind, unique: Bool, shell: String) -> String? {
        guard let command, !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "--wait needs a command"
        }
        guard CommandWaitShell.singleLine(command) != nil else {
            return "--wait needs a single-line command"
        }
        guard kind == .terminal else { return "--wait needs a terminal pane" }
        guard !unique else { return "--wait cannot be combined with --unique" }
        guard CommandWaitShell.supportsShellIntegration(shell) else {
            return "--wait needs bash or zsh; the default shell is \(CommandWaitShell.basename(shell)), which has no shell integration in Batty"
        }
        return nil
    }

    @MainActor
    static func commandWaitResponse(
        verb: String,
        payload: Data?,
        store: AppStateStore,
        shell: String,
        clock: any SchedulingClock,
        makeTab: @MainActor (TabRuntime) -> any CommandWaitTab
    ) async -> XPCResponse {
        let decoder = JSONDecoder()
        switch verb {
        case XPCVerb.paneSplit:
            guard let payload, let request = try? decoder.decode(PaneSplitRequest.self, from: payload) else {
                return XPCResponse(ok: false, error: "malformed pane split request")
            }
            guard let timeout = commandWaitTimeout(request.waitTimeoutSeconds) else {
                return XPCResponse(ok: false, error: invalidWaitTimeoutError(request.waitTimeoutSeconds))
            }
            if let refusal = commandWaitRefusal(command: request.command, kind: request.kind ?? .terminal, unique: request.unique == true, shell: shell) {
                logger.error("perform paneSplit --wait: refused: \(refusal, privacy: .public)")
                return XPCResponse(ok: false, error: refusal)
            }
            guard let targetPaneID = request.paneID ?? store.focusedPaneIDFallback() else {
                return XPCResponse(ok: false, error: "no pane to split")
            }
            let direction = SplitDirection(rawValue: request.direction.rawValue) ?? .horizontal
            guard let newPaneID = store.splitPane(id: targetPaneID, direction: direction, command: nil, kind: .terminal),
                  let tab = store.terminalPane(id: newPaneID)?.tabs.first
            else {
                return XPCResponse(ok: false, error: "unknown pane id")
            }
            let outcome = await runCommandWait(request.command ?? "", tab: tab, timeout: timeout, clock: clock, makeTab: makeTab)
            guard let outcome else { return XPCResponse(ok: false, error: "wait cancelled: client disconnected") }
            logger.info("perform paneSplit --wait -> pane=\(newPaneID, privacy: .public) result=\(outcome.result.rawValue, privacy: .public)")
            return encodeReply(PaneSplitReply(paneID: newPaneID, created: true, tabID: tab.id, exitCode: outcome.exitCode, durationMs: outcome.durationMs, waitResult: outcome.result))
        case XPCVerb.tabNew:
            guard let payload, let request = try? decoder.decode(TabNewRequest.self, from: payload) else {
                return XPCResponse(ok: false, error: "malformed tab new request")
            }
            guard let timeout = commandWaitTimeout(request.waitTimeoutSeconds) else {
                return XPCResponse(ok: false, error: invalidWaitTimeoutError(request.waitTimeoutSeconds))
            }
            if let refusal = commandWaitRefusal(command: request.command, kind: .terminal, unique: false, shell: shell) {
                logger.error("perform tabNew --wait: refused: \(refusal, privacy: .public)")
                return XPCResponse(ok: false, error: refusal)
            }
            guard let targetPaneID = request.paneID ?? store.focusedPaneIDFallback() else {
                return XPCResponse(ok: false, error: "no pane to target")
            }
            if let pane = store.terminalPane(id: targetPaneID), pane.isHidden {
                return XPCResponse(ok: false, error: "pane is hidden; show it with batty pane show before using --wait")
            }
            let created = store.newTabForXPC(paneID: targetPaneID, sourceTabID: request.sourceTabID, command: nil, workingDirectory: request.workingDirectory, background: request.background ?? false)
            switch created {
            case .unknownPane:
                return XPCResponse(ok: false, error: "unknown pane id")
            case .notTerminal:
                return XPCResponse(ok: false, error: "pane is not a terminal pane")
            case let .created(sessionID, paneID, tabID):
                guard let tab = store.tabRuntime(id: tabID) else {
                    return XPCResponse(ok: false, error: "unknown tab id")
                }
                let outcome = await runCommandWait(request.command ?? "", tab: tab, timeout: timeout, clock: clock, makeTab: makeTab)
                guard let outcome else { return XPCResponse(ok: false, error: "wait cancelled: client disconnected") }
                logger.info("perform tabNew --wait -> tab=\(tabID, privacy: .public) result=\(outcome.result.rawValue, privacy: .public)")
                return encodeReply(TabNewReply(sessionID: sessionID, paneID: paneID, tabID: tabID, exitCode: outcome.exitCode, durationMs: outcome.durationMs, waitResult: outcome.result))
            }
        default:
            return XPCResponse(ok: false, error: "unknown verb: \(verb)")
        }
    }

    /// The wire timeout as a `Duration`, or nil when `WaitTimeout` rejects it.
    /// Never trust the client: converting infinity or `1e300` to `Int` traps.
    private static func commandWaitTimeout(_ seconds: Double?) -> Duration? {
        WaitTimeout.duration(seconds ?? CommandWaitDefaults.timeoutSeconds)
    }

    private static func invalidWaitTimeoutError(_ seconds: Double?) -> String {
        "wait timeout " + (WaitTimeout.validationError(seconds ?? CommandWaitDefaults.timeoutSeconds) ?? "is out of range")
    }

    /// nil when the wait was cancelled.
    @MainActor
    private static func runCommandWait(
        _ command: String,
        tab: TabRuntime,
        timeout: Duration,
        clock: any SchedulingClock,
        makeTab: @MainActor (TabRuntime) -> any CommandWaitTab
    ) async -> (result: CommandWaitResult, exitCode: Int?, durationMs: Int?)? {
        let line = CommandWaitShell.singleLine(command) ?? command
        let outcome = await CommandWaiter.run(line, on: makeTab(tab), timeout: timeout, clock: clock)
        switch outcome {
        case let .exited(exitCode, durationNanos):
            return (.exited, exitCode, Int(durationNanos / 1_000_000))
        case .timedOut: return (.timedOut, nil, nil)
        case .shellNotReady: return (.shellNotReady, nil, nil)
        case .notStarted: return (.notStarted, nil, nil)
        case .tabClosed: return (.tabClosed, nil, nil)
        case .cancelled: return nil
        }
    }

    private static func encodeReply<T: Encodable>(_ reply: T) -> XPCResponse {
        guard let data = try? JSONEncoder().encode(reply) else {
            return XPCResponse(ok: false, error: "failed to encode reply")
        }
        return XPCResponse(ok: true, payload: data)
    }

    /// The `server` verbs (#0648, #0692). `--wait` replies once the state
    /// leaves Starting or the bound passes on `clock`.
    @MainActor
    static func serverResponse(verb: String, payload: Data?, store: AppStateStore, clock: any SchedulingClock) async -> XPCResponse {
        let decoder = JSONDecoder()
        let result: Result<ServerXPCResult, ServerXPCError>
        var wait = false
        var timeout: Double = 60
        switch verb {
        case XPCVerb.serverStart:
            guard let payload, let request = try? decoder.decode(ServerStartRequest.self, from: payload) else {
                return XPCResponse(ok: false, error: "malformed server start request")
            }
            if request.wait == true, let seconds = request.waitTimeoutSeconds, let error = WaitTimeout.validationError(seconds) {
                return XPCResponse(ok: false, error: "wait timeout \(error)")
            }
            result = store.startServerForXPC(request)
            wait = request.wait ?? false
            timeout = request.waitTimeoutSeconds ?? timeout
        case XPCVerb.serverShare:
            guard let payload, let request = try? decoder.decode(ServerShareRequest.self, from: payload) else {
                return XPCResponse(ok: false, error: "malformed server share request")
            }
            result = await store.shareServerForXPC(request)
        case XPCVerb.serverList:
            switch store.listServersForXPC() {
            case .failure(let error):
                return XPCResponse(ok: false, error: error.message)
            case .success(let reply):
                guard let data = try? JSONEncoder().encode(reply) else {
                    return XPCResponse(ok: false, error: "failed to encode server list")
                }
                return XPCResponse(ok: true, payload: data)
            }
        case XPCVerb.serverServe:
            guard let payload, let request = try? decoder.decode(ServerServeRequest.self, from: payload) else {
                return XPCResponse(ok: false, error: "malformed server serve request")
            }
            result = await store.serveStaticForXPC(request)
        case XPCVerb.serverTailnet:
            guard let payload, let request = try? decoder.decode(ServerTailnetRequest.self, from: payload) else {
                return XPCResponse(ok: false, error: "malformed server tailnet request")
            }
            result = await store.tailnetServerForXPC(request)
        default:
            guard let payload, let request = try? decoder.decode(ServerControlRequest.self, from: payload) else {
                return XPCResponse(ok: false, error: "malformed server request")
            }
            switch verb {
            case XPCVerb.serverStop: result = store.stopServerForXPC(request)
            case XPCVerb.serverUnshare: result = store.unshareServerForXPC(request)
            default: result = store.restartServerForXPC(request)
            }
        }
        let outcome: ServerXPCResult
        switch result {
        case .failure(let error):
            logger.error("perform \(verb, privacy: .public): \(error.message, privacy: .public)")
            return XPCResponse(ok: false, error: error.message)
        case .success(let value):
            outcome = value
        }
        if verb == XPCVerb.serverStop || verb == XPCVerb.serverRestart || verb == XPCVerb.serverStart {
            await outcome.entry.awaitPendingWork()
            if verb != XPCVerb.serverStart || !outcome.created, let reason = outcome.entry.stopRefusal {
                return XPCResponse(ok: false, error: "stop refused: \(reason)")
            }
            if verb == XPCVerb.serverRestart, let error = outcome.entry.lastError {
                return XPCResponse(ok: false, error: error)
            }
        }
        if wait {
            let content = outcome.entry
            let state = await Self.firstStateLeavingStarting(content, clock: clock, timeout: timeout)
            switch state {
            case nil, .starting?:
                return XPCResponse(ok: false, error: "timed out; still starting")
            case .crashed(let code)?:
                return XPCResponse(ok: false, error: "server exited (code \(code.map(String.init) ?? "unknown"))")
            case .stopped(let code, _)?:
                return XPCResponse(ok: false, error: "server stopped (code \(code.map(String.init) ?? "unknown"))")
            default:
                break
            }
        }
        guard let replyData = try? JSONEncoder().encode(store.serverReply(outcome)) else {
            return XPCResponse(ok: false, error: "failed to encode server reply")
        }
        logger.info("perform \(verb, privacy: .public) -> server=\(outcome.entry.id, privacy: .public) created=\(outcome.created, privacy: .public)")
        return XPCResponse(ok: true, payload: replyData)
    }

    /// The first state after Starting, or nil once `timeout` passes on
    /// `clock`, whichever comes first. nil at once for a timeout
    /// `WaitTimeout` rejects.
    @MainActor
    static func firstStateLeavingStarting(_ content: ServerEntry, clock: any SchedulingClock, timeout: Double) async -> ServerEntryState? {
        guard let duration = WaitTimeout.duration(timeout) else { return nil }
        var waiter: Task<Void, Never>?
        var timer: Task<Void, Never>?
        let state: ServerEntryState? = await withCheckedContinuation { (continuation: CheckedContinuation<ServerEntryState?, Never>) in
            var resumed = false
            func finish(_ value: ServerEntryState?) {
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: value)
            }
            waiter = Task { @MainActor in
                let state = await content.waitForState { $0 != .starting }
                finish(state)
            }
            timer = Task { @MainActor in
                await clock.sleep(for: duration)
                finish(nil)
            }
        }
        waiter?.cancel()
        timer?.cancel()
        return state
    }

    private static func unknownVerbResponse(_ verb: String) -> Data {
        encode(XPCResponse(ok: false, error: "unknown verb: \(verb)"))
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
                let store = AppStateStore.shared
                let snapshot = store.topologyPayload(includeDimensions: false)
                // #0439: label the snapshot with the same window
                // `defaultTargetWindow()` would act on, not always
                // `windows.first` — falls back to `.first` only if that
                // window somehow isn't in the snapshot (unreachable in
                // practice: the snapshot is built from the same `windows`
                // array `defaultTargetWindow()` reads).
                let targetWindowID = store.defaultTargetWindow()?.id.value
                let targetWindow = snapshot.windows.first { $0.id == targetWindowID } ?? snapshot.windows.first

                guard let firstSession = targetWindow?.sessions.first else {
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

/// Holds the timer for one in-flight `projectOpen`, so the completion that
/// answers the request can stop it.
@MainActor
private final class ProjectOpenWaiter {
    var timeoutTask: Task<Void, Never>?
}
