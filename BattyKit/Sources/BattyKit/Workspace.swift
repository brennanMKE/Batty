// Workspace.swift

import Foundation

struct WindowFrame: Codable, Sendable, Hashable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
}

struct WindowState: Codable, Sendable, Hashable, Identifiable {
    var id: UUID
    var frame: WindowFrame?
    var isZoomed: Bool
    var sidebarCollapsed: Bool
    var selectedSessionID: UUID?
    var sessions: [Session]

    init(
        id: UUID = UUID(),
        frame: WindowFrame? = nil,
        isZoomed: Bool = false,
        sidebarCollapsed: Bool = false,
        selectedSessionID: UUID? = nil,
        sessions: [Session]
    ) {
        precondition(!sessions.isEmpty, "WindowState must contain at least one Session")
        self.id = id
        self.frame = frame
        self.isZoomed = isZoomed
        self.sidebarCollapsed = sidebarCollapsed
        self.selectedSessionID = selectedSessionID ?? sessions[0].id
        self.sessions = sessions
    }
}

public struct BellFeedEntry: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var timestamp: Date
    public var windowID: UUID
    public var sessionID: UUID
    public var paneID: UUID
    public var tabID: UUID
    public var surfaceID: UUID
    public var message: String?
    public var seen: Bool

    public init(
        id: UUID = UUID(),
        timestamp: Date,
        windowID: UUID,
        sessionID: UUID,
        paneID: UUID,
        tabID: UUID,
        surfaceID: UUID,
        message: String? = nil,
        seen: Bool = false
    ) {
        self.id = id
        self.timestamp = timestamp
        self.windowID = windowID
        self.sessionID = sessionID
        self.paneID = paneID
        self.tabID = tabID
        self.surfaceID = surfaceID
        self.message = message
        self.seen = seen
    }
}

struct Workspace: Codable, Sendable, Hashable {
    static let currentSchemaVersion: Int = 1
    static let bellFeedCap: Int = 200

    var schemaVersion: Int
    var windows: [WindowState]
    var bellFeed: [BellFeedEntry]

    init(
        schemaVersion: Int = Workspace.currentSchemaVersion,
        windows: [WindowState],
        bellFeed: [BellFeedEntry] = []
    ) {
        self.schemaVersion = schemaVersion
        self.windows = windows
        self.bellFeed = bellFeed
    }
}

extension Workspace {
    static func empty() -> Workspace {
        Workspace(windows: [WindowState(sessions: [Session.makeDefault()])])
    }

    static let prettyEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

extension Workspace {
    mutating func recordBell(_ entry: BellFeedEntry) {
        bellFeed.insert(entry, at: 0)
        if bellFeed.count > Workspace.bellFeedCap {
            bellFeed.removeLast(bellFeed.count - Workspace.bellFeedCap)
        }
    }
}
