// SessionRuntime.swift

import Foundation
import Observation

@Observable
public final class SessionRuntime: Identifiable {
    public let id: UUID
    public var title: String
    public let tree: SplitTree
    public internal(set) var unseenBellCount: Int = 0
    public var notificationsMuted: Bool = false
    @ObservationIgnored public let paneFrames: PaneFrameTracker

    public init(
        id: UUID = UUID(),
        title: String = "Session",
        tree: SplitTree? = nil,
        unseenBellCount: Int = 0,
        notificationsMuted: Bool = false
    ) {
        self.id = id
        self.title = title
        self.tree = tree ?? SplitTree()
        self.unseenBellCount = unseenBellCount
        self.notificationsMuted = notificationsMuted
        self.paneFrames = PaneFrameTracker()
    }

    public var focusedPane: PaneRuntime {
        tree.focusedPane
    }

    public func closeFocusedTab() {
        let pane = focusedPane
        if pane.tabs.count > 1 {
            pane.closeActiveTab()
        } else if tree.allPanes.count > 1 {
            tree.removeFocusedPane()
        }
    }
}
