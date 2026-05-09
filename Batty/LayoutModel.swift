// LayoutModel.swift

import Foundation

enum SplitDirection: String, Codable, Sendable, Hashable {
    case horizontal
    case vertical
}

indirect enum SplitNode: Codable, Sendable, Hashable {
    case leaf(Pane)
    case split(direction: SplitDirection, ratio: Double, left: SplitNode, right: SplitNode)
}

struct Tab: Codable, Sendable, Hashable, Identifiable {
    var id: UUID
    var surfaceID: UUID
    var titleOverride: String?
    var lastKnownCWD: String?
    var lastSetTitle: String?
    var bellCount: Int
    var unseenBellCount: Int
    var lastBellAt: Date?
    var lastBellMessage: String?

    init(
        id: UUID = UUID(),
        surfaceID: UUID = UUID(),
        titleOverride: String? = nil,
        lastKnownCWD: String? = nil,
        lastSetTitle: String? = nil,
        bellCount: Int = 0,
        unseenBellCount: Int = 0,
        lastBellAt: Date? = nil,
        lastBellMessage: String? = nil
    ) {
        self.id = id
        self.surfaceID = surfaceID
        self.titleOverride = titleOverride
        self.lastKnownCWD = lastKnownCWD
        self.lastSetTitle = lastSetTitle
        self.bellCount = bellCount
        self.unseenBellCount = unseenBellCount
        self.lastBellAt = lastBellAt
        self.lastBellMessage = lastBellMessage
    }
}

struct Pane: Codable, Sendable, Hashable, Identifiable {
    var id: UUID
    var tabs: [Tab]
    var activeTabID: UUID
    var unseenBellCount: Int

    init(
        id: UUID = UUID(),
        tabs: [Tab],
        activeTabID: UUID? = nil,
        unseenBellCount: Int = 0
    ) {
        precondition(!tabs.isEmpty, "Pane must always contain at least one Tab")
        self.id = id
        self.tabs = tabs
        self.activeTabID = activeTabID ?? tabs[0].id
        self.unseenBellCount = unseenBellCount
    }
}

struct Session: Codable, Sendable, Hashable, Identifiable {
    var id: UUID
    var title: String
    var icon: String?
    var root: SplitNode
    var focusedPaneID: UUID
    var unseenBellCount: Int

    init(
        id: UUID = UUID(),
        title: String,
        icon: String? = nil,
        root: SplitNode,
        focusedPaneID: UUID,
        unseenBellCount: Int = 0
    ) {
        self.id = id
        self.title = title
        self.icon = icon
        self.root = root
        self.focusedPaneID = focusedPaneID
        self.unseenBellCount = unseenBellCount
    }
}

extension Session {
    static func makeDefault(title: String = "Session") -> Session {
        let tab = Tab()
        let pane = Pane(tabs: [tab])
        return Session(title: title, root: .leaf(pane), focusedPaneID: pane.id)
    }
}

extension SplitNode {
    var firstPane: Pane {
        switch self {
        case .leaf(let pane):
            return pane
        case .split(_, _, let left, _):
            return left.firstPane
        }
    }

    func contains(paneID: UUID) -> Bool {
        switch self {
        case .leaf(let pane):
            return pane.id == paneID
        case .split(_, _, let left, let right):
            return left.contains(paneID: paneID) || right.contains(paneID: paneID)
        }
    }
}
