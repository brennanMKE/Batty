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
    /// Per-session theme override. When non-nil, switching to this session
    /// applies this theme instead of the global `ThemePreference`. Not
    /// persisted — resets to nil on every launch.
    public var localThemeName: String? = nil
    /// Whether the sidebar shows this session's pane rows. Collapsed by
    /// default; `WindowRuntime.hidePane` expands it so a just-hidden pane's
    /// restore control is always reachable (#0258). Not persisted.
    public var isPaneListExpanded: Bool = false
    @ObservationIgnored public let paneFrames: PaneFrameTracker

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
        // #0281: attach every pane/tab already in the tree (whether the
        // caller-supplied tree or the default single-pane one above) to
        // this session's id, so BATTY_SESSION_ID/BATTY_PANE_ID are set
        // before any surface in it can spawn.
        self.tree.attachToSession(self.id)
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
