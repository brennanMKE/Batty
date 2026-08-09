// TopologyPayloadBuilder.swift

import BattyXPCCore
import Foundation

/// Builds `Topology*Payload` (`BattyXPCCore`) values from the live runtime
/// tree — `WindowRuntime` / `SessionRuntime` / `SplitTreeNode` /
/// `PaneRuntime` / `TabRuntime` — for the `list` and `sessionInfo` XPC
/// verbs (#0274).
///
/// Every method here only reads: no property on any runtime type is ever
/// assigned. Building a payload for a session that isn't selected, or a
/// window that isn't key, must never change `selectedSessionID`,
/// `focusedPaneID`, or `activeTabID` — the "reads must not mutate" rule
/// #0257/#0274 both call out for cross-session queries.
extension WindowRuntime {
    func topologyPayload() -> TopologyWindowPayload {
        TopologyWindowPayload(
            id: id.value,
            selectedSessionID: selectedSessionID,
            sessions: sessions.map { $0.topologyPayload(isActive: $0.id == selectedSessionID) }
        )
    }
}

extension SessionRuntime {
    /// Uses `tab.workingDirectory` (the Observation-tracked mirror), not
    /// `tab.terminal.workingDirectory` (the raw Combine value). Both are
    /// "correct" here per `TabRuntime`'s own doc comment — non-view code is
    /// explicitly allowed to read the live Combine value — but the mirror
    /// is the better choice for a different reason than convention: it is
    /// wired in `.task(id:)` and never unwired on disappear, so it keeps
    /// tracking cwd changes for background sessions and hidden panes even
    /// while their SwiftUI view isn't mounted — exactly the panes `list`
    /// and `session info` exist to report on.
    func topologyPayload(isActive: Bool) -> TopologySessionPayload {
        let anchorTab = tree.root.firstLeafPane.tabs.first
        return TopologySessionPayload(
            id: id,
            name: title,
            path: anchorTab?.workingDirectory,
            isActive: isActive,
            focusedPaneID: tree.focusedPaneID,
            root: tree.root.topologyPayload(focusedPaneID: tree.focusedPaneID)
        )
    }
}

extension SplitTreeNode {
    func topologyPayload(focusedPaneID: UUID) -> TopologySplitNodePayload {
        switch self {
        case .leaf(let pane):
            return .leaf(pane: pane.topologyPayload(isFocused: pane.id == focusedPaneID))
        case .split(let id, let direction, let ratio, let left, let right):
            // Exhaustive, not a ternary — a future third SplitDirection case
            // must fail this build rather than silently mapping to .vertical.
            let mappedDirection: TopologySplitDirection
            switch direction {
            case .horizontal: mappedDirection = .horizontal
            case .vertical: mappedDirection = .vertical
            }
            return .split(
                id: id,
                direction: mappedDirection,
                ratio: ratio,
                left: left.topologyPayload(focusedPaneID: focusedPaneID),
                right: right.topologyPayload(focusedPaneID: focusedPaneID)
            )
        }
    }
}

extension PaneRuntime {
    /// A non-terminal pane's `tabs` holds one structural placeholder
    /// `TabRuntime` that `PaneView` never renders (`PaneRuntime.kind`'s doc
    /// comment) — reporting it here would show `batty list`/`batty list
    /// --tabs` a targetable-looking terminal tab on (e.g.) a `git-status`
    /// pane, which is wrong for exactly the agent workflow this verb
    /// surface exists to serve (#0315 review round 1, finding 3). Reported
    /// as `tabs: []` for any non-terminal kind instead.
    ///
    /// `activeTabID` is not adjusted to match (`TopologyPanePayload
    /// .activeTabID` stays non-optional — see `docs/pane-kinds.md` §5,
    /// deliberately not built by #0315): a non-terminal pane's
    /// `activeTabID` still names the placeholder tab's real id, which will
    /// not appear in `tabs`. `TopologyPanePayload` also carries no `kind`
    /// field yet, so an agent parsing `list` output cannot distinguish
    /// "empty tabs, no active tab really" from any other empty-tabs pane by
    /// this field alone — a known residual gap, not a regression this fix
    /// introduces, left for whichever issue adds `kind` to the topology
    /// payload.
    func topologyPayload(isFocused: Bool) -> TopologyPanePayload {
        let visibleTabs = kind == .terminal ? tabs : []
        return TopologyPanePayload(
            id: id,
            isHidden: isHidden,
            isFocused: isFocused,
            activeTabID: activeTabID,
            tabs: visibleTabs.map { $0.topologyPayload(isActive: $0.id == activeTabID) }
        )
    }
}

extension TabRuntime {
    func topologyPayload(isActive: Bool) -> TopologyTabPayload {
        TopologyTabPayload(
            id: id,
            title: TabTitleFormatter.chipTitle(for: self),
            workingDirectory: workingDirectory,
            isActive: isActive
        )
    }
}
