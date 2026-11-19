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

extension AppStateStore {
    /// The Server Pane serving `rootRealPath` in the Session holding `paneID`.
    public func findStaticServerPane(sessionContaining paneID: UUID, root rootRealPath: String) -> PaneRuntime? {
        guard let (_, session) = locate(paneID: paneID) else { return nil }
        return session.tree.allPanes.first {
            (($0.content as? ServerPaneContent)?.backend as? InAppStaticServerBackend)?.root == rootRealPath
        }
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

    /// `serve --open`: the served URL in the default browser.
    private func openIfAsked(_ result: ServerXPCResult, open: Bool?) -> ServerXPCResult {
        guard open == true else { return result }
        openURLInBrowser(result.content.url)
        return result
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
