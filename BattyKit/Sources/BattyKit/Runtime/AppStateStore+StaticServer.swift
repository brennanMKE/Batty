// AppStateStore+StaticServer.swift

import BattyXPCCore
import Foundation
import OSLog

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "AppStateStore+StaticServer")

extension ServerXPCError {
    init(_ error: StaticServerError) {
        switch error {
        case .portInUse(let port): self = .portInUse(port)
        case .bindFailed(let reason): self = .bindFailed(reason)
        case .notADirectory(let path): self = .notADirectory(path)
        }
    }
}

public struct WebPreviewXPCResult {
    public let paneID: UUID
    public let content: WebPreviewPaneContent
    public let created: Bool
}

extension AppStateStore {
    /// The Server Pane serving `rootRealPath` in the Session holding `paneID`.
    public func findStaticServerPane(sessionContaining paneID: UUID, root rootRealPath: String) -> PaneRuntime? {
        guard let (_, session) = locate(paneID: paneID) else { return nil }
        return session.tree.allPanes.first {
            (($0.content as? ServerPaneContent)?.backend as? InAppStaticServerBackend)?.root == rootRealPath
        }
    }

    /// The change broadcaster of the in-app server listening on `port`, in
    /// any window.
    public func staticReloadBroadcaster(forPort port: Int) -> StaticReloadBroadcaster? {
        for window in windows {
            for session in window.sessions {
                for pane in session.tree.allPanes {
                    if let backend = (pane.content as? ServerPaneContent)?.backend as? InAppStaticServerBackend,
                       backend.isServing, backend.port.map(Int.init) == port {
                        return backend.broadcaster
                    }
                }
            }
        }
        return nil
    }

    /// `batty server serve` (#0649). Binds before the Pane exists, because
    /// a Server Pane's port is fixed at creation.
    public func serveStaticForXPC(_ request: ServerServeRequest) async -> Result<ServerXPCResult, ServerXPCError> {
        guard featureFlags.serverPane else { return .failure(.flagOff) }
        var requestedPort: UInt16?
        if let raw = request.port {
            guard let port = Self.validPort(raw) else { return .failure(.invalidPort) }
            requestedPort = port
        }
        let resolved = resolveCallingPane(request.paneID)
        guard case .success(let (window, _, callingPaneID)) = resolved else {
            if case .failure(let error) = resolved { return .failure(error) }
            return .failure(.noPane)
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: request.root, isDirectory: &isDirectory), isDirectory.boolValue,
              let resolver = StaticFilePathResolver(root: URL(fileURLWithPath: request.root)) else {
            return .failure(.notADirectory(request.root))
        }

        if let existing = findStaticServerPane(sessionContaining: callingPaneID, root: resolver.rootRealPath) {
            return await reuse(existing, in: window, requestedPort: requestedPort, open: request.open)
        }

        let backend = makeInAppServerBackend(resolver, request.inject ?? true)
        let port: UInt16
        do {
            port = try await backend.startServing(port: requestedPort)
        } catch {
            return .failure(ServerXPCError(error))
        }
        // The main actor was free during the bind: the calling Pane may be
        // gone, or another serve may have claimed this root.
        guard let (window, session) = locate(paneID: callingPaneID) else {
            backend.stopServing()
            return .failure(.unknownPane)
        }
        if let existing = findStaticServerPane(sessionContaining: callingPaneID, root: resolver.rootRealPath) {
            backend.stopServing()
            return await reuse(existing, in: window, requestedPort: requestedPort, open: request.open)
        }
        guard let url = URL(string: "http://127.0.0.1:\(port)/"),
              let content = createServerPane(
                session: session, window: window, callingPaneID: callingPaneID, port: port,
                url: url, statsURL: nil, split: request.split, backend: backend),
              let serverPane = session.tree.allPanes.first(where: { $0.content === content }) else {
            backend.stopServing()
            return .failure(.unknownPane)
        }
        content.startBackend()
        logger.info("server serve: pane \(serverPane.id, privacy: .public) port \(port, privacy: .public)")
        return .success(openIfAsked(ServerXPCResult(paneID: serverPane.id, content: content, created: true), open: request.open))
    }

    /// `serve --open`: a Web Preview Pane below the Server Pane, or the
    /// browser, per Settings.
    private func openIfAsked(_ result: ServerXPCResult, open: Bool?) -> ServerXPCResult {
        guard open == true else { return result }
        var opened = result
        switch ServedSiteOpenTarget.resolved(defaults: preferences) {
        case .batty:
            if case .success(let preview) = openWebPreview(url: result.content.url, besideServerPane: result.paneID) {
                opened.previewPaneID = preview.paneID
            }
        case .browser:
            openURLInBrowser(result.content.url)
        }
        return opened
    }

    // MARK: - Web Preview Panes

    public func openWebPreviewForXPC(_ request: WebPreviewRequest) -> Result<WebPreviewXPCResult, ServerXPCError> {
        guard featureFlags.serverPane else { return .failure(.flagOff) }
        guard let url = URL(string: request.url), WebPreviewURLPolicy.isAllowedTopLevel(url), WebPreviewURLPolicy.origin(of: url) != nil else {
            return .failure(.previewURLNotAllowed)
        }
        let resolved = resolveCallingPane(request.paneID)
        guard case .success(let (_, _, callingPaneID)) = resolved else {
            if case .failure(let error) = resolved { return .failure(error) }
            return .failure(.noPane)
        }
        return openWebPreview(url: url, beside: callingPaneID, direction: direction(for: request.split))
    }

    /// From a Server Pane's Open in Batty button or `serve --open`: below
    /// that Server Pane.
    public func openWebPreview(url: URL, besideServerPane serverPaneID: UUID) -> Result<WebPreviewXPCResult, ServerXPCError> {
        guard WebPreviewURLPolicy.isAllowedTopLevel(url), WebPreviewURLPolicy.origin(of: url) != nil else { return .failure(.previewURLNotAllowed) }
        return openWebPreview(url: url, beside: serverPaneID, direction: .vertical)
    }

    /// One preview per (Session, origin): the same origin again navigates
    /// the existing Pane and shows it. Keyboard focus stays where it was.
    private func openWebPreview(url: URL, beside paneID: UUID, direction: SplitDirection) -> Result<WebPreviewXPCResult, ServerXPCError> {
        guard let (window, session) = locate(paneID: paneID) else { return .failure(.unknownPane) }
        let origin = WebPreviewURLPolicy.origin(of: url)
        if let existing = session.tree.allPanes.first(where: {
            guard let preview = $0.content as? WebPreviewPaneContent else { return false }
            return WebPreviewURLPolicy.origin(of: preview.url) == origin
        }), let content = existing.content as? WebPreviewPaneContent {
            content.navigate(to: url)
            showIfHidden(existing, in: window)
            return .success(WebPreviewXPCResult(paneID: existing.id, content: content, created: false))
        }
        let focused = session.tree.focusedPaneID
        let content = makeWebPreviewContent(url) { [weak self] target in
            WebPreviewURLPolicy.origin(of: target).flatMap { self?.staticReloadBroadcaster(forPort: $0.port) }
        }
        let isSessionSelected = window.selectedSessionID == session.id && window.isWindowVisible
        guard let pane = session.tree.splitPane(id: paneID, direction: direction, kind: .webPreview, contentFactory: { _ in content }, isSessionSelected: isSessionSelected) else {
            return .failure(.unknownPane)
        }
        session.tree.focusedPaneID = focused
        let event = WatchEventPayload(type: "pane_split", sessionID: session.id, targetPaneID: pane.id)
        AppEventWatcher.shared.send(eventType: event.type, payload: event)
        logger.info("web preview: pane \(pane.id, privacy: .public)")
        return .success(WebPreviewXPCResult(paneID: pane.id, content: content, created: true))
    }

    private func reuse(_ pane: PaneRuntime, in window: WindowRuntime, requestedPort: UInt16?, open: Bool?) async -> Result<ServerXPCResult, ServerXPCError> {
        guard let content = pane.content as? ServerPaneContent, let backend = content.backend as? InAppStaticServerBackend else {
            return .failure(.unknownServer)
        }
        if let requestedPort, let current = backend.port, requestedPort != current {
            return .failure(.alreadyServing(root: backend.root, port: Int(current)))
        }
        showIfHidden(pane, in: window)
        if !backend.isServing {
            content.restart()
            await content.awaitPendingWork()
            if !backend.isServing {
                return .failure(.portInUse(Int(backend.port ?? 0)))
            }
        }
        return .success(openIfAsked(ServerXPCResult(paneID: pane.id, content: content, created: false), open: open))
    }
}
