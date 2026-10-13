// ProcessStatusFollowAction.swift

import Foundation

/// The one decision behind every visible follow-by-name control in the
/// Process Status Pane: the "Choose Process…" menu item, the header button
/// and the exited banner's button all map from ``offered(target:runState:listedName:pid:)``
/// so they cannot disagree about when the action exists or what it does.
public enum ProcessStatusFollowAction: Equatable, Sendable {
    /// Retarget to `.followingName(name)`. `seedPid` is the live process to
    /// show first, or nil when the pinned process has already exited so the
    /// next match is its successor.
    case follow(name: String, seedPid: pid_t?)
    case stopFollowing

    public static func offered(
        target: ProcessStatusPaneContent.Target?,
        runState: ProcessStatusPaneContent.RunState,
        listedName: String?,
        pid: pid_t?
    ) -> ProcessStatusFollowAction? {
        switch target {
        case .followingName:
            return .stopFollowing
        case .pinned:
            guard let listedName else { return nil }
            switch runState {
            case .running: return .follow(name: listedName, seedPid: pid)
            case .exited: return .follow(name: listedName, seedPid: nil)
            case .permissionDenied, .unavailable, .waiting: return nil
            }
        case .followingTab, nil:
            return nil
        }
    }
}
