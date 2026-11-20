// ServerPayload.swift

import Foundation

/// Payloads for the `serverStart`, `serverShare`, `serverServe`,
/// `serverList`, `serverStop`, `serverRestart`, `serverUnshare` and
/// `serverTailnet` XPC verbs (#0648, #0692, #0694). `nonisolated` at the type level for the
/// same reason as every other payload in this module.

/// Where `server start` puts its terminal Pane, split from the calling Pane.
public nonisolated enum ServerSplit: String, Codable, Sendable, CaseIterable {
    case right
    case down
}

public nonisolated enum ServerState: String, Codable, Sendable {
    case starting
    case listening
    case stopping
    case stopped
    case crashed
}

public nonisolated struct ServerStartRequest: Codable, Sendable, Equatable {
    /// The calling Pane; the terminal Pane is split from it. Nil falls back
    /// to the focused Pane.
    public var paneID: UUID?
    public var port: Int
    /// Shell text typed into the terminal.
    public var command: String
    public var workingDirectory: String
    public var url: String?
    /// Overrides the Servers list row's name.
    public var name: String?
    public var split: ServerSplit?
    /// False skips the Process Status Pane. Nil means open it.
    public var processView: Bool?
    public var wait: Bool?
    public var waitTimeoutSeconds: Double?

    public init(paneID: UUID? = nil, port: Int, command: String, workingDirectory: String, url: String? = nil, name: String? = nil, split: ServerSplit? = nil, processView: Bool? = nil, wait: Bool? = nil, waitTimeoutSeconds: Double? = nil) {
        self.paneID = paneID
        self.port = port
        self.command = command
        self.workingDirectory = workingDirectory
        self.url = url
        self.name = name
        self.split = split
        self.processView = processView
        self.wait = wait
        self.waitTimeoutSeconds = waitTimeoutSeconds
    }
}

/// `batty server share`: tracks a server Batty didn't start. Batty never
/// signals it.
public nonisolated struct ServerShareRequest: Codable, Sendable, Equatable {
    public var paneID: UUID?
    public var port: Int
    public var url: String?
    public var name: String?
    public var split: ServerSplit?
    /// False skips the Process Status Pane. Nil means open it.
    public var processView: Bool?
    /// True also shares the server on the tailnet (#0694).
    public var tailnet: Bool?

    public init(paneID: UUID? = nil, port: Int, url: String? = nil, name: String? = nil, split: ServerSplit? = nil, processView: Bool? = nil, tailnet: Bool? = nil) {
        self.paneID = paneID
        self.port = port
        self.url = url
        self.name = name
        self.split = split
        self.processView = processView
        self.tailnet = tailnet
    }
}

/// `batty server tailnet`: share a tracked server on the tailnet, or stop
/// (`off`). Names the server by id or by port.
public nonisolated struct ServerTailnetRequest: Codable, Sendable, Equatable {
    public var paneID: UUID?
    public var serverID: UUID?
    public var port: Int?
    public var off: Bool?

    public init(paneID: UUID? = nil, serverID: UUID? = nil, port: Int? = nil, off: Bool? = nil) {
        self.paneID = paneID
        self.serverID = serverID
        self.port = port
        self.off = off
    }
}

/// `batty server serve [<dir>]` (#0649). `root` is absolute (the CLI
/// resolves it). `inject` nil means on.
public nonisolated struct ServerServeRequest: Codable, Sendable, Equatable {
    public var paneID: UUID?
    public var root: String
    public var port: Int?
    public var open: Bool?
    public var inject: Bool?
    public var split: ServerSplit?

    public init(paneID: UUID? = nil, root: String, port: Int? = nil, open: Bool? = nil, inject: Bool? = nil, split: ServerSplit? = nil) {
        self.paneID = paneID
        self.root = root
        self.port = port
        self.open = open
        self.inject = inject
        self.split = split
    }
}

/// Names a server by id, or by port (app-wide).
public nonisolated struct ServerControlRequest: Codable, Sendable, Equatable {
    public var paneID: UUID?
    public var serverID: UUID?
    public var port: Int?

    public init(paneID: UUID? = nil, serverID: UUID? = nil, port: Int? = nil) {
        self.paneID = paneID
        self.serverID = serverID
        self.port = port
    }
}

public nonisolated struct ServerReply: Codable, Sendable, Equatable {
    public var serverID: UUID
    public var terminalPaneID: UUID?
    public var tabID: UUID?
    public var url: String
    public var pid: Int32?
    public var state: ServerState
    public var exitCode: Int?
    /// False when an existing server was reused.
    public var created: Bool
    /// The served folder, for an in-app static server (#0649).
    public var root: String?
    public var name: String?
    public var kind: ServerKind?
    /// The Process Status Pane watching the listener, when one is open.
    public var processPaneID: UUID?
    /// Set while the server is shared on the tailnet (#0694).
    public var tailnetURL: String?
    /// Why `share --tailnet` couldn't share on the tailnet; the share stands.
    public var tailnetError: String?

    public init(serverID: UUID, terminalPaneID: UUID? = nil, tabID: UUID? = nil, url: String, pid: Int32? = nil, state: ServerState, exitCode: Int? = nil, created: Bool, root: String? = nil, name: String? = nil, kind: ServerKind? = nil, processPaneID: UUID? = nil, tailnetURL: String? = nil, tailnetError: String? = nil) {
        self.tailnetURL = tailnetURL
        self.tailnetError = tailnetError
        self.root = root
        self.name = name
        self.kind = kind
        self.processPaneID = processPaneID
        self.serverID = serverID
        self.terminalPaneID = terminalPaneID
        self.tabID = tabID
        self.url = url
        self.pid = pid
        self.state = state
        self.exitCode = exitCode
        self.created = created
    }
}

/// How a listed server runs: `terminal` (a command in a Batty terminal
/// Pane), `external` (shared; Batty didn't start it) or `static` (a folder
/// Batty serves).
public nonisolated enum ServerKind: String, Codable, Sendable, CaseIterable {
    case terminal
    case external
    case `static`
}

public nonisolated struct ServerListItem: Codable, Sendable, Equatable {
    public var serverID: UUID
    public var name: String
    public var port: Int
    public var kind: ServerKind
    public var state: ServerState
    public var url: String
    public var tailnetURL: String?
    public var pid: Int32?
    public var terminalPaneID: UUID?
    public var processPaneID: UUID?

    public init(serverID: UUID, name: String, port: Int, kind: ServerKind, state: ServerState, url: String, tailnetURL: String? = nil, pid: Int32? = nil, terminalPaneID: UUID? = nil, processPaneID: UUID? = nil) {
        self.serverID = serverID
        self.name = name
        self.port = port
        self.kind = kind
        self.state = state
        self.url = url
        self.tailnetURL = tailnetURL
        self.pid = pid
        self.terminalPaneID = terminalPaneID
        self.processPaneID = processPaneID
    }
}

/// `serverList`: every tracked server, in registration order.
public nonisolated struct ServerListReply: Codable, Sendable, Equatable {
    public var servers: [ServerListItem]

    public init(servers: [ServerListItem]) {
        self.servers = servers
    }
}
