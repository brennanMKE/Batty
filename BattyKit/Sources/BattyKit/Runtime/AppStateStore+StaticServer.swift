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

        let root = resolver.rootRealPath
        if let existing = servers.entry(root: root) {
            let existingEngine = existing.served?.engine ?? .builtin
            if let engine = request.engine, engine != existingEngine {
                return .failure(.alreadyServing(root: root, port: Int(existing.port)))
            }
            if existingEngine == .photon {
                if let requestedPort, requestedPort != existing.port {
                    return .failure(.alreadyServing(root: root, port: Int(existing.port)))
                }
                let result = ServerXPCResult(entry: existing, created: false)
                if request.open == true, case .starting = existing.state {
                    existing.opensBrowserOnFirstListener = true
                    return .success(result)
                }
                return .success(openIfAsked(result, open: request.open))
            }
            return await reuse(existing, requestedPort: requestedPort, open: request.open)
        }

        if request.engine != .builtin {
            let photon = await locatePhoton(request.searchPath)
            if let photon {
                return servePhoton(photon, root: root, requestedPort: requestedPort, request: request)
            }
            if request.engine == .photon { return .failure(.photonNotInstalled) }
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
        entry.served = (root, .builtin)
        entry.startBackend()
        logger.info("server serve: built-in server \(entry.id, privacy: .public) port \(port, privacy: .public)")
        return .success(openIfAsked(ServerXPCResult(entry: entry, created: true), open: request.open))
    }

    /// `photon serve` in a new terminal Pane split from the calling Pane.
    /// The entry's tick marks it listening once photon binds.
    private func servePhoton(_ photon: URL, root: String, requestedPort: UInt16?, request: ServerServeRequest) -> Result<ServerXPCResult, ServerXPCError> {
        // The main actor was free while photon was looked for.
        if let existing = servers.entry(root: root) {
            return .failure(.alreadyServing(root: root, port: Int(existing.port)))
        }
        var port = requestedPort
        if port == nil {
            for _ in 0..<5 {
                guard let picked = pickServePort() else { break }
                if servers.entry(port: picked) == nil {
                    port = picked
                    break
                }
            }
        }
        guard let port else { return .failure(.bindFailed("no free port on 127.0.0.1")) }
        if servers.entry(port: port) != nil { return .failure(.portInUse(Int(port))) }
        let resolved = resolveCallingPane(request.paneID)
        guard case .success(let (_, _, callingPaneID)) = resolved else {
            if case .failure(let error) = resolved { return .failure(error) }
            return .failure(.noPane)
        }
        guard let url = URL(string: "http://127.0.0.1:\(port)/") else {
            return .failure(.bindFailed("no URL for port \(port)"))
        }
        guard let (_, tab, spawnBaseline) = makeServerTerminal(from: callingPaneID, direction: direction(for: request.split), workingDirectory: root) else {
            return .failure(.unknownPane)
        }
        let command = PhotonServeCommand.commandLine(photon: photon, root: root, port: port)
        let backend = terminalBackend(tabID: tab.id, command: command, workingDirectory: root, spawnBaseline: spawnBaseline)
        let entry = registerServer(port: port, url: url, backend: backend, anchorPaneID: callingPaneID)
        entry.served = (root, .photon)
        entry.stopBounds = .photonServe
        entry.wantsProcessStatus = true
        entry.opensBrowserOnFirstListener = request.open == true
        entry.startBackend()
        logger.info("server serve: photon server \(entry.id, privacy: .public) port \(port, privacy: .public)")
        return .success(ServerXPCResult(entry: entry, created: true))
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
