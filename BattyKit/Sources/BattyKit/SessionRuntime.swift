// SessionRuntime.swift

import Foundation
import Observation

@Observable
public final class SessionRuntime: Identifiable {
    public let id: UUID
    public var title: String
    public let tree: SplitTree
    public internal(set) var unseenBellCount: Int = 0
    @ObservationIgnored public let paneFrames: PaneFrameTracker

    public init(
        id: UUID = UUID(),
        title: String = "Session",
        tree: SplitTree? = nil,
        unseenBellCount: Int = 0
    ) {
        self.id = id
        self.title = title
        self.tree = tree ?? SplitTree()
        self.unseenBellCount = unseenBellCount
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
