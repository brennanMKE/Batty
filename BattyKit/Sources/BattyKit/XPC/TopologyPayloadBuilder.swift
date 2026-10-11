// TopologyPayloadBuilder.swift







import AppKit
@_exported import BattyXPCCore // Re-export for the Rectangle type used throughout.
import Foundation

/// WindowRuntime / SessionRuntime / SplitTreeNode / PaneRuntime / TabRuntime → Topology*Payload.
/// Builds the wire-format payloads for `batty list` / `session info`.



extension WindowRuntime {
    




    func topologyPayload(includeDimensions: Bool = false) -> TopologyWindowPayload {
        TopologyWindowPayload(
            id: id.value,
            selectedSessionID: selectedSessionID,
            sessions: sessions.map { $0.topologyPayload(isActive: $0.id == selectedSessionID, includeDimensions: includeDimensions) }
        )
    }




}

extension SessionRuntime {
    /// Uses `tab.workingDirectory` (the Observation-tracked mirror), not
    /// `tab.terminal.workingDirectory` (the raw Combine value). Both are
    /// "correct" here per `TabRuntime`'s own doc comment — this is an
    /// on-demand CLI query, not the pwd delegate callback itself, so the
    /// live Combine value isn't stale here (#0436) — but the mirror is the
    /// better choice for a different reason than staleness: it is wired in
    /// `.task(id:)` and never unwired on disappear, so it keeps
    /// tracking cwd changes for background sessions and hidden panes even
    /// while their SwiftUI view isn't mounted — exactly the panes `list`
    /// and `session info` exist to report on.
    




    func topologyPayload(isActive: Bool, includeDimensions: Bool = false) -> TopologySessionPayload {
        let anchorTab = tree.root.firstLeafPane.tabs.first
        return TopologySessionPayload(
            id: id,
            name: title,
            path: anchorTab?.workingDirectory,
            isActive: isActive,
            focusedPaneID: tree.focusedPaneID,
            root: tree.root.topologyPayload(focusedPaneID: tree.focusedPaneID, includeDimensions: includeDimensions)
        )
    }



}

extension SplitTreeNode {
    




    func topologyPayload(focusedPaneID: UUID, includeDimensions: Bool = false) -> TopologySplitNodePayload {
        switch self {
        case .leaf(let pane):
            return .leaf(pane: pane.topologyPayload(isFocused: pane.id == focusedPaneID, includeDimensions: includeDimensions))
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
                left: left.topologyPayload(focusedPaneID: focusedPaneID, includeDimensions: includeDimensions),
                right: right.topologyPayload(focusedPaneID: focusedPaneID, includeDimensions: includeDimensions)
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
    /// not appear in `tabs`. Since #0379, `TopologyPanePayload.kind` lets
    /// an agent distinguish "empty tabs because this is a non-terminal
    /// pane" from any other empty-tabs pane, so this is no longer the
    /// residual gap it once was.
    





    


    func topologyPayload(isFocused: Bool, includeDimensions: Bool = false) -> TopologyPanePayload {
        let visibleTabs = kind == .terminal ? tabs : []
        var frame: Rectangle?
        // A hidden Pane's retained surface keeps its last laid-out frame, which
        // no longer describes anything on screen.
        if includeDimensions && !isHidden {
            // Get dimensions from the pane's terminal view, fall back to layer bounds if layout hasn't run.
            for tab in tabs where tab.terminalNSView != nil {
                let view = tab.terminalNSView!
                if !view.frame.width.isZero && !view.frame.height.isZero {
                    frame = Rectangle(
                        x: Int(view.frame.origin.x),
                        y: Int(view.frame.origin.y),
                        width: Int(view.frame.width),
                        height: Int(view.frame.height)
                    )
                } else if !view.bounds.width.isZero && !view.bounds.height.isZero {
                    frame = Rectangle(
                        x: Int(view.frame.origin.x),
                        y: Int(view.frame.origin.y),
                        width: Int(view.bounds.width),
                        height: Int(view.bounds.height)
                    )
                } else if !view.subviews.isEmpty {
                    // Some ghostty views leave the terminal as a child view.
                    let subview = view.subviews[0]
                    frame = Rectangle(
                        x: Int(view.frame.origin.x + subview.frame.origin.x),
                        y: Int(view.frame.origin.y + subview.frame.origin.y),
                        width: Int(subview.frame.width),
                        height: Int(subview.frame.height)
                    )
                }
            }
        }




        return TopologyPanePayload(
            id: id,
            isHidden: isHidden,
            isFocused: isFocused,
            activeTabID: activeTabID,
            tabs: visibleTabs.map { $0.topologyPayload(isActive: $0.id == activeTabID) },
            kind: kind,
            frame: frame,
            visibleRect: nil
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
