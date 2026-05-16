// PaneDragController.swift

import Foundation
import Observation
import SwiftUI

/// Per-session state for an in-flight pane drag-and-drop swap.
///
/// `PaneView`'s drag handle pushes updates here as the gesture progresses;
/// `SplitContainerView` reads `cursorLocation` to position the translucent
/// preview, and each `PaneView` reads `dropTargetPaneID` to highlight when
/// the cursor is over it. On drop, the controller asks the owning
/// `SplitTree` to swap the two leaves.
///
/// Coordinates are in the named coordinate space `"session"` (defined in
/// `SessionDetailView`).
@Observable
public final class PaneDragController {
    /// id of the pane currently being dragged, if any.
    public private(set) var draggedPaneID: UUID?
    /// The size of the dragged pane at drag start, used to size the preview.
    public private(set) var draggedPaneSize: CGSize = .zero
    /// Live cursor position in the session coordinate space.
    public private(set) var cursorLocation: CGPoint = .zero
    /// The pane currently under the cursor (excludes the dragged pane).
    public private(set) var dropTargetPaneID: UUID?

    public init() {}

    public var isDragging: Bool {
        draggedPaneID != nil
    }

    func begin(paneID: UUID, paneSize: CGSize, cursor: CGPoint) {
        draggedPaneID = paneID
        draggedPaneSize = paneSize
        cursorLocation = cursor
        dropTargetPaneID = nil
    }

    func update(cursor: CGPoint, frames: [UUID: CGRect]) {
        guard let draggedID = draggedPaneID else { return }
        cursorLocation = cursor
        let hit = frames.first { id, frame in
            id != draggedID && frame.contains(cursor)
        }?.key
        if hit != dropTargetPaneID {
            dropTargetPaneID = hit
        }
    }

    /// Returns the resolved swap targets if a drop is valid, then clears
    /// drag state. Returns `nil` when the drop should be a no-op.
    func end() -> (UUID, UUID)? {
        defer { reset() }
        guard let dragged = draggedPaneID, let target = dropTargetPaneID else {
            return nil
        }
        return (dragged, target)
    }

    func cancel() {
        reset()
    }

    private func reset() {
        draggedPaneID = nil
        draggedPaneSize = .zero
        cursorLocation = .zero
        dropTargetPaneID = nil
    }
}
