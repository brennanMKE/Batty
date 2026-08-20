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
    /// Index into `SessionColor.allCases`, assigned once by
    /// `WindowRuntime`'s least-used round-robin at creation and stable for
    /// the Session's lifetime (#0335). A plain `Int`, not `SessionColor`
    /// itself, so a future persisted Session (`Concepts.md`: "Persisted:
    /// nothing" today) stores a trivially codable value. `var`, not `let`,
    /// so a future explicit user override (#0336) can write it without
    /// restructuring this type.
    public var colorIndex: Int
    @ObservationIgnored public let paneFrames: PaneFrameTracker

    public init(
        id: UUID = UUID(),
        title: String = "Session",
        tree: SplitTree? = nil,
        unseenBellCount: Int = 0,
        notificationsMuted: Bool = false,
        titleOverride: Bool = false,
        colorIndex: Int = 0
    ) {
        self.id = id
        self.title = title
        self.tree = tree ?? SplitTree()
        self.unseenBellCount = unseenBellCount
        self.notificationsMuted = notificationsMuted
        self.titleOverride = titleOverride
        self.colorIndex = colorIndex
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

    /// The resolved palette color for `colorIndex`. Falls back to `.blue`
    /// for an out-of-range index rather than crashing — defensive only;
    /// every assignment path keeps `colorIndex` within `SessionColor`'s
    /// case count.
    public var sessionColor: SessionColor {
        SessionColor(rawValue: colorIndex) ?? .blue
    }

    /// `focusedPane`, but `nil` when it isn't a `.terminal`-kind pane.
    ///
    /// Every Tab-scoped command (Cmd-T, Cmd-W, tab-switching, Exit Shell —
    /// whether dispatched from the menu bar, the global keyboard-shortcut
    /// monitor, or the Command Palette) must resolve its target pane
    /// through this, not `focusedPane` directly: a non-terminal pane's one
    /// `TabRuntime` is a structural placeholder `PaneView` never renders
    /// (`PaneRuntime.kind`'s doc comment), and mutating it (adding a
    /// second invisible tab, closing the only one) is a real bug, not a
    /// cosmetic one — see `docs/pane-kinds.md`'s `#0315` implementation
    /// note for the three independent dispatch paths this was found
    /// reachable from in review (#0315 review rounds 1 and 2, finding 2).
    public var focusedTerminalPane: PaneRuntime? {
        let pane = focusedPane
        return pane.kind == .terminal ? pane : nil
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
