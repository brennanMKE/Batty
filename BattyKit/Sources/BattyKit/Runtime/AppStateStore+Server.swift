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
    case nothingListening(Int)
    case portShared(Int)
    case notManaged
    case managedServer
    case tailnet(String)

    public var message: String {
        switch self {
        case .flagOff: return "servers are not available in this build"
        case .invalidPort: return "port must be between 1 and 65535"
        case .noPane: return "no pane to target"
        case .unknownPane: return "unknown pane id"
        case .unknownServer: return "no server with that id or port"
        case .cannotRestart: return "this server has no command to restart"
        case .stopRefused(let reason): return "stop refused: \(reason)"
        case .notADirectory(let path): return "not a directory: \(path)"
        case .portInUse(let port): return "port \(port) is in use"
        case .alreadyServing(let root, let port): return "already serving \(root) on port \(port); stop it first"
        case .bindFailed(let reason): return "could not listen on 127.0.0.1: \(reason)"
        case .nothingListening(let port): return "nothing of yours is listening on 127.0.0.1:\(port)"
        case .portShared(let port): return "port \(port) is held by a shared server Batty didn't start; stop that process, then run server start"
        case .notManaged: return "this server was shared, not started by Batty, so Batty won't signal it; use batty server unshare to remove it from the list"
        case .managedServer: return "Batty started this server; use batty server stop"
        case .tailnet(let message): return message
        }
    }
}

public struct ServerXPCResult {
    public let entry: ServerEntry
    public let created: Bool
    /// `share --tailnet` shared the server but not on the tailnet.
    public var tailnetError: String?

    public init(entry: ServerEntry, created: Bool, tailnetError: String? = nil) {
        self.entry = entry
        self.created = created
        self.tailnetError = tailnetError
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
        entry.onListenerChange = { [weak self] entry, pid in
            self?.serverListenerChanged(entry, pid: pid)
        }
        servers.register(entry)
        tailnet.refreshStatusIfStale()
        return entry
    }

    // MARK: - Process Status Pane

    func processStatusContent(paneID: UUID) -> ProcessStatusPaneContent? {
        for window in windows {
            for session in window.sessions {
                if let pane = session.tree.allPanes.first(where: { $0.id == paneID }) {
                    return pane.content as? ProcessStatusPaneContent
                }
            }
        }
        return nil
    }

    /// The entry's Process Status Pane, retargeted to `pid`, or a new one
    /// split from `anchor` with focus unchanged. Nil when no Pane resolves.
    @discardableResult
    func ensureProcessStatusPane(for entry: ServerEntry, pid: pid_t, anchor: UUID?, direction: SplitDirection) -> UUID? {
        if let id = entry.processStatusPaneID, let content = processStatusContent(paneID: id) {
            if content.target != .pinned(pid) { content.retarget(to: .pinned(pid)) }
            return id
        }
        entry.processStatusPaneID = nil
        guard let anchor, let (_, session) = locate(paneID: anchor) else { return nil }
        let focused = session.tree.focusedPaneID
        guard let id = splitPane(id: anchor, direction: direction, kind: .processStatus, processStatusPid: pid) else { return nil }
        session.tree.focusedPaneID = focused
        entry.processStatusPaneID = id
        return id
    }

    /// Runs from the entry's tick. Retargets an open Process Status Pane;
    /// opens one only on a started server's first listener, below its
    /// terminal Pane, and never reopens a Pane the user closed.
    func serverListenerChanged(_ entry: ServerEntry, pid: pid_t) {
        if let id = entry.processStatusPaneID, let content = processStatusContent(paneID: id) {
            if content.target != .pinned(pid) { content.retarget(to: .pinned(pid)) }
            return
        }
        guard entry.wantsProcessStatus else { return }
        entry.wantsProcessStatus = false
        let terminal = serverTerminalTabID(entry).flatMap(paneID(holdingTab:))
        let anchor = terminal ?? entry.anchorPaneID.flatMap { locate(paneID: $0) != nil ? $0 : nil }
        ensureProcessStatusPane(for: entry, pid: pid, anchor: anchor, direction: .vertical)
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
            } else {
                if entry.backend.kind == .external, case .listening = entry.state {
                    return .failure(.portShared(Int(port)))
                }
                if let (_, tab, spawnBaseline) = makeServerTerminal(from: callingPaneID, direction: direction, workingDirectory: cwd) {
                    entry.anchorPaneID = callingPaneID
                    entry.replaceBackend(terminalBackend(tabID: tab.id, command: request.command, workingDirectory: cwd, spawnBaseline: spawnBaseline))
                }
            }
            apply(request.name, processView: request.processView, to: entry)
            logger.info("server start: reused server \(entry.id, privacy: .public) for port \(port, privacy: .public)")
            return .success(ServerXPCResult(entry: entry, created: false))
        }

        guard let (_, tab, spawnBaseline) = makeServerTerminal(from: callingPaneID, direction: direction, workingDirectory: cwd) else {
            return .failure(.unknownPane)
        }
        let backend = terminalBackend(tabID: tab.id, command: request.command, workingDirectory: cwd, spawnBaseline: spawnBaseline)
        let entry = registerServer(port: port, url: request.url.flatMap(URL.init(string:)), backend: backend, anchorPaneID: callingPaneID)
        apply(request.name, processView: request.processView, to: entry)
        entry.startBackend()
        logger.info("server start: server \(entry.id, privacy: .public) port \(port, privacy: .public)")
        return .success(ServerXPCResult(entry: entry, created: true))
    }

    private func apply(_ name: String?, processView: Bool?, to entry: ServerEntry) {
        if let name, entry.customName != name { entry.customName = name }
        entry.wantsProcessStatus = processView != false
    }

    public func shareServerForXPC(_ request: ServerShareRequest) async -> Result<ServerXPCResult, ServerXPCError> {
        guard featureFlags.servers else { return .failure(.flagOff) }
        guard let port = Self.validPort(request.port) else { return .failure(.invalidPort) }
        guard let pid = await serverPortScanner.listeners(port: port).first else {
            return .failure(.nothingListening(request.port))
        }
        let entry: ServerEntry
        let created: Bool
        if let existing = servers.entry(port: port) {
            entry = existing
            created = false
        } else {
            entry = registerServer(port: port, url: request.url.flatMap(URL.init(string:)), backend: ExternalProcessServerBackend(), anchorPaneID: request.paneID)
            entry.startBackend()
            created = true
        }
        if let name = request.name, entry.customName != name { entry.customName = name }
        if request.processView != false {
            let anchor = request.paneID.flatMap { locate(paneID: $0) != nil ? $0 : nil } ?? focusedPaneIDFallback()
            ensureProcessStatusPane(for: entry, pid: pid, anchor: anchor, direction: direction(for: request.split))
        }
        logger.info("server share: server \(entry.id, privacy: .public) port \(port, privacy: .public) created=\(created, privacy: .public)")
        var result = ServerXPCResult(entry: entry, created: created)
        if request.tailnet == true, case .failure(let error) = await tailnet.share(entry: entry).value {
            result.tailnetError = error.message
        }
        return .success(result)
    }

    public func tailnetServerForXPC(_ request: ServerTailnetRequest) async -> Result<ServerXPCResult, ServerXPCError> {
        let control = ServerControlRequest(paneID: request.paneID, serverID: request.serverID, port: request.port)
        let resolved = resolveServer(control)
        guard case .success(let entry) = resolved else {
            if case .failure(let error) = resolved { return .failure(error) }
            return .failure(.unknownServer)
        }
        if request.off == true {
            if case .failure(let error) = await tailnet.unshare(port: entry.port, entry: entry, reportForeign: true).value {
                return .failure(.tailnet(error.message))
            }
        } else if case .failure(let error) = await tailnet.share(entry: entry).value {
            return .failure(.tailnet(error.message))
        }
        return .success(ServerXPCResult(entry: entry, created: false))
    }

    public func unshareServerForXPC(_ request: ServerControlRequest) -> Result<ServerXPCResult, ServerXPCError> {
        resolveServer(request).flatMap { entry in
            guard entry.backend.kind == .external else { return .failure(.managedServer) }
            servers.remove(id: entry.id)
            return .success(ServerXPCResult(entry: entry, created: false))
        }
    }

    public func listServersForXPC() -> Result<ServerListReply, ServerXPCError> {
        guard featureFlags.servers else { return .failure(.flagOff) }
        return .success(ServerListReply(servers: servers.entries.map(serverListItem)))
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

    private func resolveManagedServer(_ request: ServerControlRequest) -> Result<ServerEntry, ServerXPCError> {
        resolveServer(request).flatMap { entry in
            entry.backend.kind == .external ? .failure(.notManaged) : .success(entry)
        }
    }

    public func stopServerForXPC(_ request: ServerControlRequest) -> Result<ServerXPCResult, ServerXPCError> {
        resolveManagedServer(request).map { entry in
            entry.stop()
            return ServerXPCResult(entry: entry, created: false)
        }
    }

    public func restartServerForXPC(_ request: ServerControlRequest) -> Result<ServerXPCResult, ServerXPCError> {
        resolveManagedServer(request).flatMap { entry in
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

    public func shareServerOnTailnet(_ entry: ServerEntry) {
        _ = tailnet.share(entry: entry)
    }

    public func stopSharingServerOnTailnet(_ entry: ServerEntry) {
        _ = tailnet.unshare(port: entry.port, entry: entry)
    }

    public func openServerInBrowser(_ entry: ServerEntry) {
        openURLInBrowser(entry.url)
    }

    /// The terminal Tab running the server's command, when it still exists.
    public func serverTerminalTabID(_ entry: ServerEntry) -> UUID? {
        guard let backend = entry.backend as? TerminalTabServerBackend, backend.isAvailable else { return nil }
        return backend.tabID
    }

    /// Removes a shared server from the list; signals nothing.
    public func unshareServer(_ entry: ServerEntry) {
        guard entry.backend.kind == .external else { return }
        servers.remove(id: entry.id)
    }

    public func showServerTerminal(_ entry: ServerEntry) {
        guard let tabID = serverTerminalTabID(entry), let paneID = paneID(holdingTab: tabID),
              let (_, session) = locate(paneID: paneID) else { return }
        jumpToTab(sessionID: session.id, tabID: tabID)
    }

    private func wireState(_ entry: ServerEntry) -> (state: ServerState, pid: Int32?, exitCode: Int?) {
        switch entry.state {
        case _ where entry.backend is InProcessServerBackend:
            return ((entry.backend as? InProcessServerBackend)?.isServing == true ? .listening : .stopped, entry.listenerPid, nil)
        case .starting: return (.starting, entry.listenerPid, nil)
        case .listening(let listener): return (.listening, listener ?? entry.listenerPid, nil)
        case .stopping: return (.stopping, entry.listenerPid, nil)
        case .stopped(let code, _): return (.stopped, entry.listenerPid, code)
        case .crashed(let code): return (.crashed, entry.listenerPid, code)
        }
    }

    private func liveProcessPaneID(_ entry: ServerEntry) -> UUID? {
        entry.processStatusPaneID.flatMap { processStatusContent(paneID: $0) != nil ? $0 : nil }
    }

    func serverListItem(_ entry: ServerEntry) -> ServerListItem {
        let wire = wireState(entry)
        let tabID = (entry.backend as? TerminalTabServerBackend)?.tabID
        return ServerListItem(
            serverID: entry.id, name: ServerEntryDisplay.name(for: entry), port: Int(entry.port),
            kind: ServerEntryDisplay.kind(entry.backend.kind), state: wire.state, url: entry.url.absoluteString,
            tailnetURL: entry.tailnetURL?.absoluteString, pid: wire.pid,
            terminalPaneID: tabID.flatMap(paneID(holdingTab:)), processPaneID: liveProcessPaneID(entry)
        )
    }

    /// The wire reply for a server as it stands.
    public func serverReply(_ result: ServerXPCResult) -> ServerReply {
        let entry = result.entry
        let tabID = (entry.backend as? TerminalTabServerBackend)?.tabID
        let wire = wireState(entry)
        return ServerReply(
            serverID: entry.id, terminalPaneID: tabID.flatMap(paneID(holdingTab:)), tabID: tabID,
            url: entry.url.absoluteString, pid: wire.pid, state: wire.state, exitCode: wire.exitCode, created: result.created,
            root: (entry.backend as? InAppStaticServerBackend)?.root,
            name: ServerEntryDisplay.name(for: entry), kind: ServerEntryDisplay.kind(entry.backend.kind),
            processPaneID: liveProcessPaneID(entry),
            tailnetURL: entry.tailnetURL?.absoluteString, tailnetError: result.tailnetError
        )
    }
}
