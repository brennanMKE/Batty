// ServerPayload.swift

import Foundation

/// Payloads for the `serverStart`, `serverAttach`, `serverStop` and
/// `serverRestart` XPC verbs (#0648). `nonisolated` at the type level for the
/// same reason as every other payload in this module.

/// Where a new Server Pane goes, overriding Settings.
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
    /// The calling Pane; its Session gets the Server Pane. Nil falls back to
    /// the focused Pane.
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
    /// The command Restart runs. Without it the Pane has no Restart.
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

/// Names the Server Pane by id, or by port within the calling Pane's
/// Session.
public nonisolated struct ServerControlRequest: Codable, Sendable, Equatable {
    public var paneID: UUID?
    public var serverPaneID: UUID?
    public var port: Int?

    public init(paneID: UUID? = nil, serverPaneID: UUID? = nil, port: Int? = nil) {
        self.paneID = paneID
        self.serverPaneID = serverPaneID
        self.port = port
    }
}

public nonisolated struct ServerReply: Codable, Sendable, Equatable {
    public var paneID: UUID
    public var terminalPaneID: UUID?
    public var tabID: UUID?
    public var url: String
    public var pid: Int32?
    public var state: ServerState
    public var exitCode: Int?
    /// False when an existing Server Pane was reused.
    public var created: Bool

    public init(paneID: UUID, terminalPaneID: UUID? = nil, tabID: UUID? = nil, url: String, pid: Int32? = nil, state: ServerState, exitCode: Int? = nil, created: Bool) {
        self.paneID = paneID
        self.terminalPaneID = terminalPaneID
        self.tabID = tabID
        self.url = url
        self.pid = pid
        self.state = state
        self.exitCode = exitCode
        self.created = created
    }
}
