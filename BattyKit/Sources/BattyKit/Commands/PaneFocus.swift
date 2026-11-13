// PaneFocus.swift

import Foundation
import SwiftUI

public enum PaneFocusDirection: Sendable {
    case left
    case right
    case up
    case down
}

/// Unobserved on purpose: `focusPane(adjacent:)` reads it on demand, and an
/// observable tracker would re-run every reading view on each resize.
public final class PaneFrameTracker {
    public internal(set) var frames: [UUID: CGRect] = [:]
    private var owners: [UUID: UUID] = [:]

    public init() {}

    /// `owner` identifies the recording view instance, so a rebuilt Pane's
    /// stale instance disappearing after its successor recorded cannot
    /// remove the successor's entry.
    func record(_ frame: CGRect, for paneID: UUID, owner: UUID) {
        if frames[paneID] != frame { frames[paneID] = frame }
        if owners[paneID] != owner { owners[paneID] = owner }
    }

    func remove(paneID: UUID, owner: UUID) {
        guard owners[paneID] == owner else { return }
        frames[paneID] = nil
        owners[paneID] = nil
    }
}

extension EnvironmentValues {
    @Entry var paneFrameTracker: PaneFrameTracker? = nil
}

extension SessionRuntime {
    public func focusPane(adjacent direction: PaneFocusDirection) {
        let frames = paneFrames.frames
        let currentID = tree.focusedPaneID
        guard let current = frames[currentID] else { return }

        let epsilon: CGFloat = 2

        let candidates: [(UUID, CGRect)] = frames.compactMap { id, frame in
            guard id != currentID else { return nil }
            switch direction {
            case .right where frame.minX >= current.maxX - epsilon:
                return (id, frame)
            case .left where frame.maxX <= current.minX + epsilon:
                return (id, frame)
            case .down where frame.minY >= current.maxY - epsilon:
                return (id, frame)
            case .up where frame.maxY <= current.minY + epsilon:
                return (id, frame)
            default:
                return nil
            }
        }

        guard let best = candidates.min(by: { a, b in
            score(from: current, to: a.1, direction: direction)
            < score(from: current, to: b.1, direction: direction)
        })?.0 else {
            return
        }

        tree.focusedPaneID = best
    }

    private func score(from a: CGRect, to b: CGRect, direction: PaneFocusDirection) -> CGFloat {
        let aCenter = CGPoint(x: a.midX, y: a.midY)
        let bCenter = CGPoint(x: b.midX, y: b.midY)
        switch direction {
        case .left, .right:
            return abs(aCenter.y - bCenter.y) + abs(aCenter.x - bCenter.x) * 0.1
        case .up, .down:
            return abs(aCenter.x - bCenter.x) + abs(aCenter.y - bCenter.y) * 0.1
        }
    }
}
