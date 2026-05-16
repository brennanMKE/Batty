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
    /// `true` once the user has explicitly renamed the session via the
    /// sidebar rename action. Auto-derivation paths (project-name from
    /// CWD, name-cache lookups) check this and skip the rewrite — a
    /// user-set name pins permanently. See `#0089`.
    public var titleOverride: Bool = false
    /// Wall-clock timestamp of the last time this session became the
    /// selected session. Drives recency ranking in the Open Quickly panel
    /// (`#0128`). Stamped from `AppStateStore.markActiveTabSeen()`.
    @ObservationIgnored public var lastFocusedAt: Date?
    @ObservationIgnored public let paneFrames: PaneFrameTracker
    public let paneDrag: PaneDragController

    public init(
        id: UUID = UUID(),
        title: String = "Session",
        tree: SplitTree? = nil,
        unseenBellCount: Int = 0,
        notificationsMuted: Bool = false,
        titleOverride: Bool = false
    ) {
        self.id = id
        self.title = title
        self.tree = tree ?? SplitTree()
        self.unseenBellCount = unseenBellCount
        self.notificationsMuted = notificationsMuted
        self.titleOverride = titleOverride
        self.paneFrames = PaneFrameTracker()
        self.paneDrag = PaneDragController()
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
