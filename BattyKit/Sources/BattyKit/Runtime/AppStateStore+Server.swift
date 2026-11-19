// AppStateStore+Server.swift

import BattyXPCCore
import Foundation
import OSLog

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "AppStateStore+Server")

public enum ServerXPCError: Error, Equatable, Sendable {
    case flagOff
    case invalidPort
    case noPane
    case unknownPane
    case unknownServer
    case cannotRestart
    case stopRefused(String)
    case notADirectory(String)
    case portInUse(Int)
    case alreadyServing(root: String, port: Int)
    case bindFailed(String)

    public var message: String {
        switch self {
        case .flagOff: return "server panes are not available in this build"
        case .invalidPort: return "port must be between 1 and 65535"
        case .noPane: return "no pane to target"
        case .unknownPane: return "unknown pane id"
        case .unknownServer: return "no server pane for that port in this session"
        case .cannotRestart: return "this server has no command to restart; attach with --command"
        case .stopRefused(let reason): return "stop refused: \(reason)"
        case .notADirectory(let path): return "not a directory: \(path)"
        case .portInUse(let port): return "port \(port) is in use"
        case .alreadyServing(let root, let port): return "already serving \(root) on port \(port); stop it first"
        case .bindFailed(let reason): return "could not listen on 127.0.0.1: \(reason)"
        }
    }
}

public struct ServerXPCResult {
    public let paneID: UUID
    public let content: ServerPaneContent
    public let created: Bool

    public init(paneID: UUID, content: ServerPaneContent, created: Bool) {
        self.paneID = paneID
        self.content = content
        self.created = created
    }
}

extension AppStateStore {
    // MARK: - Lookup

    func locate(paneID: UUID) -> (WindowRuntime, SessionRuntime)? {
        for window in windows {
            if let session = window.sessions.first(where: { $0.tree.allPanes.contains { $0.id == paneID } }) {
                return (window, session)
            }
        }
        return nil
    }

    /// The terminal Pane `id`, in any window.
    func terminalPane(id: UUID) -> PaneRuntime? {
        for window in windows {
            for session in window.sessions {
                if let pane = session.tree.allPanes.first(where: { $0.id == id && $0.kind == .terminal }) { return pane }
            }
        }
        return nil
    }

    func tabRuntime(id: UUID) -> TabRuntime? {
        for window in windows {
            for session in window.sessions {
                for pane in session.tree.allPanes where pane.kind == .terminal {
                    if let tab = pane.tabs.first(where: { $0.id == id }) { return tab }
                }
            }
        }
        return nil
    }

    /// The terminal Pane holding `tabID`.
    func paneID(holdingTab tabID: UUID) -> UUID? {
        for window in windows {
            for session in window.sessions {
                if let pane = session.tree.allPanes.first(where: { $0.kind == .terminal && $0.tabs.contains { $0.id == tabID } }) {
                    return pane.id
                }
            }
        }
        return nil
    }

    /// The Server Pane for `port` in the Session holding `paneID`, hidden or
    /// not.
    public func findServerPane(sessionContaining paneID: UUID, port: UInt16) -> PaneRuntime? {
        guard let (_, session) = locate(paneID: paneID) else { return nil }
        return session.tree.allPanes.first { ($0.content as? ServerPaneContent)?.port == port }
    }

    public func serverContent(paneID: UUID) -> ServerPaneContent? {
        guard let (_, session) = locate(paneID: paneID) else { return nil }
        return session.tree.allPanes.first { $0.id == paneID }?.content as? ServerPaneContent
    }

    func resolveCallingPane(_ paneID: UUID?) -> Result<(WindowRuntime, SessionRuntime, UUID), ServerXPCError> {
        guard let target = paneID ?? focusedPaneIDFallback() else { return .failure(.noPane) }
        guard let (window, session) = locate(paneID: target) else { return .failure(.unknownPane) }
        return .success((window, session, target))
    }

    static func validPort(_ port: Int) -> UInt16? {
        (1...65535).contains(port) ? UInt16(port) : nil
    }

    func direction(for split: ServerSplit?) -> SplitDirection {
        switch split {
        case .right: return .horizontal
        case .down: return .vertical
        case nil: return ServerPanePlacement.resolved(defaults: preferences).direction
        }
    }

    func showIfHidden(_ pane: PaneRuntime, in window: WindowRuntime) {
        if pane.isHidden { window.showPane(id: pane.id) }
    }

    // MARK: - Building Panes

    private func terminalBackend(tabID: UUID, command: String, workingDirectory: String?, spawnBaseline: ShellSpawnBaseline) -> TerminalTabServerBackend {
        TerminalTabServerBackend(tabID: tabID, command: command, workingDirectory: workingDirectory, spawnBaseline: spawnBaseline) { [weak self] id in
            self?.tabRuntime(id: id).map { TabRuntimeServerTerminalSink(tab: $0) }
        }
    }

    /// A new terminal Pane below `serverPaneID`, focus unchanged.
    private func makeServerTerminal(under serverPaneID: UUID, workingDirectory: String?) -> (paneID: UUID, tab: TabRuntime, spawnBaseline: ShellSpawnBaseline)? {
        guard let (window, session) = locate(paneID: serverPaneID) else { return nil }
        let focused = session.tree.focusedPaneID
        let spawnBaseline = ShellSpawnBaseline.now()
        let tab = TabRuntime(workingDirectory: workingDirectory)
        let isSessionSelected = window.selectedSessionID == session.id && window.isWindowVisible
        guard let pane = session.tree.splitPane(id: serverPaneID, direction: .vertical, tabs: [tab], isSessionSelected: isSessionSelected) else { return nil }
        session.tree.focusedPaneID = focused
        let event = WatchEventPayload(type: "pane_split", sessionID: session.id, targetPaneID: pane.id)
        AppEventWatcher.shared.send(eventType: event.type, payload: event)
        return (pane.id, tab, spawnBaseline)
    }

    private func wireRestart(_ content: ServerPaneContent, serverPaneID: UUID) {
        content.makeTerminalBackend = { [weak self] command, workingDirectory in
            guard let self, let (_, tab, spawnBaseline) = self.makeServerTerminal(under: serverPaneID, workingDirectory: workingDirectory) else { return nil }
            return self.terminalBackend(tabID: tab.id, command: command, workingDirectory: workingDirectory, spawnBaseline: spawnBaseline)
        }
    }

    func createServerPane(
        session: SessionRuntime, window: WindowRuntime, callingPaneID: UUID,
        port: UInt16, url: URL?, statsURL: URL?, split: ServerSplit?, backend: ServerBackend
    ) -> ServerPaneContent? {
        let focused = session.tree.focusedPaneID
        let content = makeServerContent(port, url, statsURL, backend)
        let isSessionSelected = window.selectedSessionID == session.id && window.isWindowVisible
        guard let pane = session.tree.splitPane(id: callingPaneID, direction: direction(for: split), kind: .server, contentFactory: { _ in content }, isSessionSelected: isSessionSelected) else { return nil }
        session.tree.focusedPaneID = focused
        let event = WatchEventPayload(type: "pane_split", sessionID: session.id, targetPaneID: pane.id)
        AppEventWatcher.shared.send(eventType: event.type, payload: event)
        wireRestart(content, serverPaneID: pane.id)
        return content
    }

    // MARK: - Verbs

    public func startServerForXPC(_ request: ServerStartRequest) -> Result<ServerXPCResult, ServerXPCError> {
        guard featureFlags.serverPane else { return .failure(.flagOff) }
        guard let port = Self.validPort(request.port) else { return .failure(.invalidPort) }
        let resolved = resolveCallingPane(request.paneID)
        guard case .success(let (window, session, callingPaneID)) = resolved else {
            if case .failure(let error) = resolved { return .failure(error) }
            return .failure(.noPane)
        }
        let cwd = request.workingDirectory

        if let existing = findServerPane(sessionContaining: callingPaneID, port: port), let content = existing.content as? ServerPaneContent {
            if let inApp = content.backend as? InAppStaticServerBackend {
                return .failure(.alreadyServing(root: inApp.root, port: Int(port)))
            }
            showIfHidden(existing, in: window)
            if let backend = content.backend as? TerminalTabServerBackend, backend.isAvailable {
                content.update(command: request.command, workingDirectory: cwd)
                content.restart()
            } else if let (_, tab, spawnBaseline) = makeServerTerminal(under: existing.id, workingDirectory: cwd) {
                let backend = terminalBackend(tabID: tab.id, command: request.command, workingDirectory: cwd, spawnBaseline: spawnBaseline)
                if content.backend.kind == .external {
                    content.convert(to: backend)
                } else {
                    content.replaceBackend(backend)
                }
            }
            logger.info("server start: reused pane \(existing.id, privacy: .public) for port \(port, privacy: .public)")
            return .success(ServerXPCResult(paneID: existing.id, content: content, created: false))
        }

        let spawnBaseline = ShellSpawnBaseline.now()
        let tab = TabRuntime(workingDirectory: cwd)
        let backend = terminalBackend(tabID: tab.id, command: request.command, workingDirectory: cwd, spawnBaseline: spawnBaseline)
        guard let content = createServerPane(
            session: session, window: window, callingPaneID: callingPaneID, port: port,
            url: request.url.flatMap(URL.init(string:)), statsURL: request.statsURL.flatMap(URL.init(string:)),
            split: request.split, backend: backend
        ), let serverPane = session.tree.allPanes.first(where: { $0.content === content }) else { return .failure(.unknownPane) }
        let focused = session.tree.focusedPaneID
        let isSessionSelected = window.selectedSessionID == session.id && window.isWindowVisible
        if let terminal = session.tree.splitPane(id: serverPane.id, direction: .vertical, tabs: [tab], isSessionSelected: isSessionSelected) {
            session.tree.focusedPaneID = focused
            let event = WatchEventPayload(type: "pane_split", sessionID: session.id, targetPaneID: terminal.id)
            AppEventWatcher.shared.send(eventType: event.type, payload: event)
        }
        content.startBackend()
        logger.info("server start: pane \(serverPane.id, privacy: .public) port \(port, privacy: .public)")
        return .success(ServerXPCResult(paneID: serverPane.id, content: content, created: true))
    }

    public func attachServerForXPC(_ request: ServerAttachRequest) -> Result<ServerXPCResult, ServerXPCError> {
        guard featureFlags.serverPane else { return .failure(.flagOff) }
        guard let port = Self.validPort(request.port) else { return .failure(.invalidPort) }
        let resolved = resolveCallingPane(request.paneID)
        guard case .success(let (window, session, callingPaneID)) = resolved else {
            if case .failure(let error) = resolved { return .failure(error) }
            return .failure(.noPane)
        }
        if let existing = findServerPane(sessionContaining: callingPaneID, port: port), let content = existing.content as? ServerPaneContent {
            showIfHidden(existing, in: window)
            return .success(ServerXPCResult(paneID: existing.id, content: content, created: false))
        }
        let backend = ExternalProcessServerBackend(command: request.command, workingDirectory: request.workingDirectory)
        guard let content = createServerPane(
            session: session, window: window, callingPaneID: callingPaneID, port: port,
            url: request.url.flatMap(URL.init(string:)), statsURL: request.statsURL.flatMap(URL.init(string:)),
            split: request.split, backend: backend
        ), let serverPane = session.tree.allPanes.first(where: { $0.content === content }) else { return .failure(.unknownPane) }
        content.startBackend()
        return .success(ServerXPCResult(paneID: serverPane.id, content: content, created: true))
    }

    private func resolveServer(_ request: ServerControlRequest) -> Result<(UUID, ServerPaneContent), ServerXPCError> {
        guard featureFlags.serverPane else { return .failure(.flagOff) }
        if let id = request.serverPaneID {
            guard let content = serverContent(paneID: id) else { return .failure(.unknownServer) }
            return .success((id, content))
        }
        guard let rawPort = request.port else { return .failure(.unknownServer) }
        guard let port = Self.validPort(rawPort) else { return .failure(.invalidPort) }
        guard let callingPaneID = request.paneID ?? focusedPaneIDFallback() else { return .failure(.noPane) }
        guard locate(paneID: callingPaneID) != nil else { return .failure(.unknownPane) }
        guard let pane = findServerPane(sessionContaining: callingPaneID, port: port), let content = pane.content as? ServerPaneContent else {
            return .failure(.unknownServer)
        }
        return .success((pane.id, content))
    }

    public func stopServerForXPC(_ request: ServerControlRequest) -> Result<ServerXPCResult, ServerXPCError> {
        resolveServer(request).map { id, content in
            content.stop()
            return ServerXPCResult(paneID: id, content: content, created: false)
        }
    }

    public func restartServerForXPC(_ request: ServerControlRequest) -> Result<ServerXPCResult, ServerXPCError> {
        resolveServer(request).flatMap { id, content in
            if let reason = content.stopRefusal { return .failure(.stopRefused(reason)) }
            guard content.canRestart else { return .failure(.cannotRestart) }
            content.restart()
            return .success(ServerXPCResult(paneID: id, content: content, created: false))
        }
    }

    /// The wire reply for a Server Pane as it stands.
    public func serverReply(_ result: ServerXPCResult) -> ServerReply {
        let content = result.content
        let tabID = (content.backend as? TerminalTabServerBackend)?.tabID
        let state: ServerState
        var exitCode: Int?
        var pid: Int32?
        switch content.state {
        case _ where content.backend is InProcessServerBackend:
            state = (content.backend as? InProcessServerBackend)?.isServing == true ? .listening : .stopped
        case .starting: state = .starting
        case .listening(let listener): state = .listening; pid = listener
        case .stopping: state = .stopping
        case .stopped(let code, _): state = .stopped; exitCode = code
        case .crashed(let code): state = .crashed; exitCode = code
        }
        return ServerReply(
            paneID: result.paneID, terminalPaneID: tabID.flatMap(paneID(holdingTab:)), tabID: tabID,
            url: content.url.absoluteString, pid: pid ?? content.listenerPid, state: state, exitCode: exitCode, created: result.created,
            root: (content.backend as? InAppStaticServerBackend)?.root
        )
    }
}
