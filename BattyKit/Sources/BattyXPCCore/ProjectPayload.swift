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

/// `batty project create` (no `target`) and `batty project edit <target>`.
/// A nil field keeps the stored value on edit and takes the default on
/// create. There is deliberately no field that approves startup commands.
public nonisolated struct ProjectWriteRequest: Codable, Sendable, Equatable {
    public enum LayoutSource: Codable, Sendable, Equatable {
        case preset(String)
        case document(ProjectLayoutDocument)
        /// The Session to capture; nil is the focused Session.
        case fromSession(UUID?)
    }

    public enum BackgroundChoice: Codable, Sendable, Equatable {
        case hosted(set: String, title: String)
        case hostedID(String)
        case myImage(digest: String)
        /// An absolute path; the CLI resolves relative ones.
        case file(String)
        case none
    }

    /// Edit only: the Project's name or UUID.
    public var target: String?
    public var name: String?
    public var rootPath: String?
    public var color: String?
    public var colorHex: String?
    public var symbol: String?
    public var symbolName: String?
    public var themeDark: String?
    public var themeLight: String?
    public var clearTheme: Bool
    public var layout: LayoutSource?
    public var background: BackgroundChoice?
    public var imageOpacityPercent: Int?
    public var terminalOpacityPercent: Int?
    public var startupCommands: [String]?
    public var callerSessionID: UUID?

    /// A hosted image may need downloading before the reply.
    public static let timeoutSeconds = 90

    public init(
        target: String? = nil, name: String? = nil, rootPath: String? = nil,
        color: String? = nil, colorHex: String? = nil, symbol: String? = nil, symbolName: String? = nil,
        themeDark: String? = nil, themeLight: String? = nil, clearTheme: Bool = false,
        layout: LayoutSource? = nil, background: BackgroundChoice? = nil,
        imageOpacityPercent: Int? = nil, terminalOpacityPercent: Int? = nil,
        startupCommands: [String]? = nil, callerSessionID: UUID? = nil
    ) {
        self.target = target
        self.name = name
        self.rootPath = rootPath
        self.color = color
        self.colorHex = colorHex
        self.symbol = symbol
        self.symbolName = symbolName
        self.themeDark = themeDark
        self.themeLight = themeLight
        self.clearTheme = clearTheme
        self.layout = layout
        self.background = background
        self.imageOpacityPercent = imageOpacityPercent
        self.terminalOpacityPercent = terminalOpacityPercent
        self.startupCommands = startupCommands
        self.callerSessionID = callerSessionID
    }
}

public nonisolated struct ProjectWriteReply: Codable, Sendable, Equatable {
    public let id: UUID
    public let name: String
    public let rootPath: String
    public let paneCount: Int
    public let tabCount: Int
    public let created: Bool
    public let warnings: [String]
    /// Changed fields an open Session picks up only the next time the
    /// Project opens (today only `layout`).
    public let appliesOnNextOpen: [String]

    public init(id: UUID, name: String, rootPath: String, paneCount: Int, tabCount: Int, created: Bool, warnings: [String], appliesOnNextOpen: [String]) {
        self.id = id
        self.name = name
        self.rootPath = rootPath
        self.paneCount = paneCount
        self.tabCount = tabCount
        self.created = created
        self.warnings = warnings
        self.appliesOnNextOpen = appliesOnNextOpen
    }
}
