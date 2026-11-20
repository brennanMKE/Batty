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
    /// `batty server serve` (#0649). Binds before the entry exists, because
    /// an entry's port is fixed at creation.
    public func serveStaticForXPC(_ request: ServerServeRequest) async -> Result<ServerXPCResult, ServerXPCError> {
        guard featureFlags.servers else { return .failure(.flagOff) }
        var requestedPort: UInt16?
        if let raw = request.port {
            guard let port = Self.validPort(raw) else { return .failure(.invalidPort) }
            requestedPort = port
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: request.root, isDirectory: &isDirectory), isDirectory.boolValue,
              let resolver = StaticFilePathResolver(root: URL(fileURLWithPath: request.root)) else {
            return .failure(.notADirectory(request.root))
        }

        if let existing = servers.entry(root: resolver.rootRealPath) {
            return await reuse(existing, requestedPort: requestedPort, open: request.open)
        }

        let backend = makeInAppServerBackend(resolver, request.inject ?? true)
        let port: UInt16
        do {
            port = try await backend.startServing(port: requestedPort)
        } catch {
            return .failure(ServerXPCError(error))
        }
        // The main actor was free during the bind: another serve may have
        // claimed this root.
        if let existing = servers.entry(root: resolver.rootRealPath) {
            backend.stopServing()
            return await reuse(existing, requestedPort: requestedPort, open: request.open)
        }
        guard let url = URL(string: "http://127.0.0.1:\(port)/") else {
            backend.stopServing()
            return .failure(.bindFailed("no URL for port \(port)"))
        }
        let entry = registerServer(port: port, url: url, backend: backend, anchorPaneID: request.paneID)
        entry.startBackend()
        logger.info("server serve: server \(entry.id, privacy: .public) port \(port, privacy: .public)")
        return .success(openIfAsked(ServerXPCResult(entry: entry, created: true), open: request.open))
    }

    /// `serve --open`: the served URL in the default browser.
    private func openIfAsked(_ result: ServerXPCResult, open: Bool?) -> ServerXPCResult {
        guard open == true else { return result }
        openURLInBrowser(result.entry.url)
        return result
    }

    private func reuse(_ entry: ServerEntry, requestedPort: UInt16?, open: Bool?) async -> Result<ServerXPCResult, ServerXPCError> {
        guard let backend = entry.backend as? InAppStaticServerBackend else {
            return .failure(.unknownServer)
        }
        if let requestedPort, let current = backend.port, requestedPort != current {
            return .failure(.alreadyServing(root: backend.root, port: Int(current)))
        }
        if !backend.isServing {
            entry.restart()
            await entry.awaitPendingWork()
            if !backend.isServing {
                return .failure(.portInUse(Int(backend.port ?? 0)))
            }
        }
        return .success(openIfAsked(ServerXPCResult(entry: entry, created: false), open: open))
    }
}
