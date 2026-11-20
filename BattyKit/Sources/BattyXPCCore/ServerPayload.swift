// ServerPayload.swift

import Foundation

/// Payloads for the `serverStart`, `serverAttach`, `serverStop` and
/// `serverRestart` XPC verbs (#0648). `nonisolated` at the type level for the
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
    public var statsURL: String?
    public var split: ServerSplit?
    public var wait: Bool?
    public var waitTimeoutSeconds: Double?

    public init(paneID: UUID? = nil, port: Int, command: String, workingDirectory: String, url: String? = nil, statsURL: String? = nil, split: ServerSplit? = nil, wait: Bool? = nil, waitTimeoutSeconds: Double? = nil) {
        self.paneID = paneID
        self.port = port
        self.command = command
        self.workingDirectory = workingDirectory
        self.url = url
        self.statsURL = statsURL
        self.split = split
        self.wait = wait
        self.waitTimeoutSeconds = waitTimeoutSeconds
    }
}

public nonisolated struct ServerAttachRequest: Codable, Sendable, Equatable {
    public var paneID: UUID?
    public var port: Int
    public var url: String?
    public var statsURL: String?
    /// The command Restart runs. Without it the server has no Restart.
    public var command: String?
    public var workingDirectory: String?
    public var split: ServerSplit?
    public var wait: Bool?
    public var waitTimeoutSeconds: Double?

    public init(paneID: UUID? = nil, port: Int, url: String? = nil, statsURL: String? = nil, command: String? = nil, workingDirectory: String? = nil, split: ServerSplit? = nil, wait: Bool? = nil, waitTimeoutSeconds: Double? = nil) {
        self.paneID = paneID
        self.port = port
        self.url = url
        self.statsURL = statsURL
        self.command = command
        self.workingDirectory = workingDirectory
        self.split = split
        self.wait = wait
        self.waitTimeoutSeconds = waitTimeoutSeconds
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

    public init(serverID: UUID, terminalPaneID: UUID? = nil, tabID: UUID? = nil, url: String, pid: Int32? = nil, state: ServerState, exitCode: Int? = nil, created: Bool, root: String? = nil) {
        self.root = root
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
