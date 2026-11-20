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
        case .flagOff: return "servers are not available in this build"
        case .invalidPort: return "port must be between 1 and 65535"
        case .noPane: return "no pane to target"
        case .unknownPane: return "unknown pane id"
        case .unknownServer: return "no server with that id or port"
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
    public let entry: ServerEntry
    public let created: Bool

    public init(entry: ServerEntry, created: Bool) {
        self.entry = entry
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

    func resolveCallingPane(_ paneID: UUID?) -> Result<(WindowRuntime, SessionRuntime, UUID), ServerXPCError> {
        guard let target = paneID ?? focusedPaneIDFallback() else { return .failure(.noPane) }
        guard let (window, session) = locate(paneID: target) else { return .failure(.unknownPane) }
        return .success((window, session, target))
    }

    static func validPort(_ port: Int) -> UInt16? {
        (1...65535).contains(port) ? UInt16(port) : nil
    }

    func direction(for split: ServerSplit?) -> SplitDirection {
        split == .down ? .vertical : .horizontal
    }

    // MARK: - Building Panes

    private func terminalBackend(tabID: UUID, command: String, workingDirectory: String?, spawnBaseline: ShellSpawnBaseline) -> TerminalTabServerBackend {
        TerminalTabServerBackend(tabID: tabID, command: command, workingDirectory: workingDirectory, spawnBaseline: spawnBaseline) { [weak self] id in
            self?.tabRuntime(id: id).map { TabRuntimeServerTerminalSink(tab: $0) }
        }
    }

    /// A new terminal Pane split from `anchorPaneID`, focus unchanged.
    private func makeServerTerminal(from anchorPaneID: UUID, direction: SplitDirection, workingDirectory: String?) -> (paneID: UUID, tab: TabRuntime, spawnBaseline: ShellSpawnBaseline)? {
        guard let (window, session) = locate(paneID: anchorPaneID) else { return nil }
        let focused = session.tree.focusedPaneID
        let spawnBaseline = ShellSpawnBaseline.now()
        let tab = TabRuntime(workingDirectory: workingDirectory)
        let isSessionSelected = window.selectedSessionID == session.id && window.isWindowVisible
        guard let pane = session.tree.splitPane(id: anchorPaneID, direction: direction, tabs: [tab], isSessionSelected: isSessionSelected) else { return nil }
        session.tree.focusedPaneID = focused
        let event = WatchEventPayload(type: "pane_split", sessionID: session.id, targetPaneID: pane.id)
        AppEventWatcher.shared.send(eventType: event.type, payload: event)
        return (pane.id, tab, spawnBaseline)
    }

    /// A terminal backend in a new terminal Pane split from the entry's
    /// anchor, or from the focused Pane once the anchor is gone.
    private func makeAnchoredTerminalBackend(for entry: ServerEntry, command: String, workingDirectory: String?) -> TerminalTabServerBackend? {
        let anchor = entry.anchorPaneID.flatMap { locate(paneID: $0) != nil ? $0 : nil } ?? focusedPaneIDFallback()
        guard let anchor, let (_, tab, spawnBaseline) = makeServerTerminal(from: anchor, direction: .horizontal, workingDirectory: workingDirectory) else { return nil }
        return terminalBackend(tabID: tab.id, command: command, workingDirectory: workingDirectory, spawnBaseline: spawnBaseline)
    }

    func registerServer(port: UInt16, url: URL?, backend: ServerBackend, anchorPaneID: UUID?) -> ServerEntry {
        let entry = makeServerEntry(port, url, backend)
        entry.anchorPaneID = anchorPaneID
        entry.makeTerminalBackend = { [weak self, weak entry] command, workingDirectory in
            guard let self, let entry else { return nil }
            return self.makeAnchoredTerminalBackend(for: entry, command: command, workingDirectory: workingDirectory)
        }
        servers.register(entry)
        return entry
    }

    // MARK: - Verbs

    public func startServerForXPC(_ request: ServerStartRequest) -> Result<ServerXPCResult, ServerXPCError> {
        guard featureFlags.servers else { return .failure(.flagOff) }
        guard let port = Self.validPort(request.port) else { return .failure(.invalidPort) }
        let resolved = resolveCallingPane(request.paneID)
        guard case .success(let (_, _, callingPaneID)) = resolved else {
            if case .failure(let error) = resolved { return .failure(error) }
            return .failure(.noPane)
        }
        let cwd = request.workingDirectory
        let direction = direction(for: request.split)

        if let entry = servers.entry(port: port) {
            if let inApp = entry.backend as? InAppStaticServerBackend {
                return .failure(.alreadyServing(root: inApp.root, port: Int(port)))
            }
            if let backend = entry.backend as? TerminalTabServerBackend, backend.isAvailable {
                entry.update(command: request.command, workingDirectory: cwd)
                entry.restart()
            } else if let (_, tab, spawnBaseline) = makeServerTerminal(from: callingPaneID, direction: direction, workingDirectory: cwd) {
                entry.anchorPaneID = callingPaneID
                let backend = terminalBackend(tabID: tab.id, command: request.command, workingDirectory: cwd, spawnBaseline: spawnBaseline)
                if entry.backend.kind == .external {
                    entry.convert(to: backend)
                } else {
                    entry.replaceBackend(backend)
                }
            }
            logger.info("server start: reused server \(entry.id, privacy: .public) for port \(port, privacy: .public)")
            return .success(ServerXPCResult(entry: entry, created: false))
        }

        guard let (_, tab, spawnBaseline) = makeServerTerminal(from: callingPaneID, direction: direction, workingDirectory: cwd) else {
            return .failure(.unknownPane)
        }
        let backend = terminalBackend(tabID: tab.id, command: request.command, workingDirectory: cwd, spawnBaseline: spawnBaseline)
        let entry = registerServer(port: port, url: request.url.flatMap(URL.init(string:)), backend: backend, anchorPaneID: callingPaneID)
        entry.startBackend()
        logger.info("server start: server \(entry.id, privacy: .public) port \(port, privacy: .public)")
        return .success(ServerXPCResult(entry: entry, created: true))
    }

    public func attachServerForXPC(_ request: ServerAttachRequest) -> Result<ServerXPCResult, ServerXPCError> {
        guard featureFlags.servers else { return .failure(.flagOff) }
        guard let port = Self.validPort(request.port) else { return .failure(.invalidPort) }
        if let entry = servers.entry(port: port) {
            return .success(ServerXPCResult(entry: entry, created: false))
        }
        let backend = ExternalProcessServerBackend(command: request.command, workingDirectory: request.workingDirectory)
        let entry = registerServer(port: port, url: request.url.flatMap(URL.init(string:)), backend: backend, anchorPaneID: request.paneID)
        entry.startBackend()
        return .success(ServerXPCResult(entry: entry, created: true))
    }

    private func resolveServer(_ request: ServerControlRequest) -> Result<ServerEntry, ServerXPCError> {
        guard featureFlags.servers else { return .failure(.flagOff) }
        if let id = request.serverID {
            guard let entry = servers.entry(id: id) else { return .failure(.unknownServer) }
            return .success(entry)
        }
        guard let rawPort = request.port else { return .failure(.unknownServer) }
        guard let port = Self.validPort(rawPort) else { return .failure(.invalidPort) }
        guard let entry = servers.entry(port: port) else { return .failure(.unknownServer) }
        return .success(entry)
    }

    public func stopServerForXPC(_ request: ServerControlRequest) -> Result<ServerXPCResult, ServerXPCError> {
        resolveServer(request).map { entry in
            entry.stop()
            return ServerXPCResult(entry: entry, created: false)
        }
    }

    public func restartServerForXPC(_ request: ServerControlRequest) -> Result<ServerXPCResult, ServerXPCError> {
        resolveServer(request).flatMap { entry in
            if let reason = entry.stopRefusal { return .failure(.stopRefused(reason)) }
            guard entry.canRestart else { return .failure(.cannotRestart) }
            entry.restart()
            return .success(ServerXPCResult(entry: entry, created: false))
        }
    }

    // MARK: - Servers list actions (event origin)

    public func copyServerURL(_ entry: ServerEntry) {
        copyToPasteboard(entry.url.absoluteString)
    }

    public func copyServerTailnetURL(_ entry: ServerEntry) {
        guard let url = entry.tailnetURL else { return }
        copyToPasteboard(url.absoluteString)
    }

    public func openServerInBrowser(_ entry: ServerEntry) {
        openURLInBrowser(entry.url)
    }

    /// The terminal Tab running the server's command, when it still exists.
    public func serverTerminalTabID(_ entry: ServerEntry) -> UUID? {
        guard let backend = entry.backend as? TerminalTabServerBackend, backend.isAvailable else { return nil }
        return backend.tabID
    }

    public func showServerTerminal(_ entry: ServerEntry) {
        guard let tabID = serverTerminalTabID(entry), let paneID = paneID(holdingTab: tabID),
              let (_, session) = locate(paneID: paneID) else { return }
        jumpToTab(sessionID: session.id, tabID: tabID)
    }

    /// The wire reply for a server as it stands.
    public func serverReply(_ result: ServerXPCResult) -> ServerReply {
        let content = result.entry
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
            serverID: result.entry.id, terminalPaneID: tabID.flatMap(paneID(holdingTab:)), tabID: tabID,
            url: content.url.absoluteString, pid: pid ?? content.listenerPid, state: state, exitCode: exitCode, created: result.created,
            root: (content.backend as? InAppStaticServerBackend)?.root
        )
    }
}
