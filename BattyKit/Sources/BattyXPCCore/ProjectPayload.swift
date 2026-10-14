// ProjectPayload.swift

import Foundation

/// Payloads for the `projectList` and `projectOpen` XPC verbs. `nonisolated` at the type level for the same reason as every
/// other payload in this module.

/// One saved Project as `batty project list` shows it. `rootPath` is the
/// absolute path as stored; the human-readable listing abbreviates the home
/// directory to `~` on the CLI side, `--json` keeps it absolute.
public nonisolated struct ProjectListEntry: Codable, Sendable, Equatable {
    public let id: UUID
    public let name: String
    public let rootPath: String
    public let paneCount: Int
    /// A Session opened from this Project exists in some Window.
    public let isOpen: Bool

    public init(id: UUID, name: String, rootPath: String, paneCount: Int, isOpen: Bool) {
        self.id = id
        self.name = name
        self.rootPath = rootPath
        self.paneCount = paneCount
        self.isOpen = isOpen
    }
}

/// Saved Projects in store order. There is no request payload.
public nonisolated struct ProjectListReply: Codable, Sendable, Equatable {
    public let projects: [ProjectListEntry]

    public init(projects: [ProjectListEntry]) {
        self.projects = projects
    }
}

/// `openNew` asks for another Session even when one from the Project is
/// already open (`batty project open --new`). There is deliberately no field
/// that skips the startup-command trust prompt: commands never run without
/// the user's consent.
public nonisolated struct ProjectOpenRequest: Codable, Sendable, Equatable {
    public let name: String
    public let openNew: Bool

    /// How long the app holds a `projectOpen` reply for the user to answer
    /// the startup-command trust sheet before it withdraws the sheet and
    /// replies `awaitingConfirmation`. The CLI waits a little longer than
    /// this so the app's reply, not a client timeout, ends the call.
    public static let confirmationBoundSeconds = 120

    public init(name: String, openNew: Bool = false) {
        self.name = name
        self.openNew = openNew
    }
}

public nonisolated struct ProjectOpenReply: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable {
        /// The Session exists (created or focused); `sessionID` and `paneID`
        /// are set.
        case opened
        /// The Project's startup commands need the user's approval and the
        /// sheet in Batty was not answered within the app's bound. Nothing
        /// was opened and the request was withdrawn; `sessionID` and
        /// `paneID` are nil.
        case awaitingConfirmation
    }

    public let status: Status
    /// The Project's stored name (the request's name matches
    /// case-insensitively).
    public let name: String
    public let sessionID: UUID?
    /// The Session's focused Pane.
    public let paneID: UUID?
    /// `false` when an existing Session was focused instead.
    public let created: Bool

    public init(status: Status, name: String, sessionID: UUID?, paneID: UUID?, created: Bool) {
        self.status = status
        self.name = name
        self.sessionID = sessionID
        self.paneID = paneID
        self.created = created
    }
}
