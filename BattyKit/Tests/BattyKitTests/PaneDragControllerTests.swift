// PaneDragControllerTests.swift

import Foundation
import Testing
@testable import BattyKit

@MainActor
struct PaneDragControllerTests {

    @Test func initialStateIsIdle() {
        let controller = PaneDragController()
        #expect(!controller.isDragging)
        #expect(controller.draggedPaneID == nil)
        #expect(controller.dropTargetPaneID == nil)
    }

    @Test func beginStartsDragAndSetsCursor() {
        let controller = PaneDragController()
        let paneID = UUID()
        controller.begin(
            paneID: paneID,
            paneSize: CGSize(width: 400, height: 300),
            cursor: CGPoint(x: 50, y: 60)
        )
        #expect(controller.isDragging)
        #expect(controller.draggedPaneID == paneID)
        #expect(controller.draggedPaneSize == CGSize(width: 400, height: 300))
        #expect(controller.cursorLocation == CGPoint(x: 50, y: 60))
        #expect(controller.dropTargetPaneID == nil)
    }

    @Test func updatePicksFrameContainingCursorExcludingDraggedPane() {
        let controller = PaneDragController()
        let draggedID = UUID()
        let otherID = UUID()
        controller.begin(
            paneID: draggedID,
            paneSize: .zero,
            cursor: .zero
        )
        let frames: [UUID: CGRect] = [
            draggedID: CGRect(x: 0, y: 0, width: 100, height: 100),
            otherID: CGRect(x: 200, y: 0, width: 100, height: 100)
        ]
        controller.update(cursor: CGPoint(x: 250, y: 50), frames: frames)
        #expect(controller.dropTargetPaneID == otherID)
    }

    @Test func updateOverDraggedPaneClearsTarget() {
        let controller = PaneDragController()
        let draggedID = UUID()
        let otherID = UUID()
        controller.begin(paneID: draggedID, paneSize: .zero, cursor: .zero)
        let frames: [UUID: CGRect] = [
            draggedID: CGRect(x: 0, y: 0, width: 100, height: 100),
            otherID: CGRect(x: 200, y: 0, width: 100, height: 100)
        ]
        controller.update(cursor: CGPoint(x: 250, y: 50), frames: frames)
        controller.update(cursor: CGPoint(x: 50, y: 50), frames: frames)
        #expect(controller.dropTargetPaneID == nil)
    }

    @Test func endReturnsDraggedAndTargetWhenValid() {
        let controller = PaneDragController()
        let draggedID = UUID()
        let otherID = UUID()
        controller.begin(paneID: draggedID, paneSize: .zero, cursor: .zero)
        controller.update(
            cursor: CGPoint(x: 250, y: 50),
            frames: [
                draggedID: CGRect(x: 0, y: 0, width: 100, height: 100),
                otherID: CGRect(x: 200, y: 0, width: 100, height: 100)
            ]
        )
        let result = controller.end()
        #expect(result?.0 == draggedID)
        #expect(result?.1 == otherID)
        #expect(!controller.isDragging)
    }

    @Test func endReturnsNilWhenNoTarget() {
        let controller = PaneDragController()
        let draggedID = UUID()
        controller.begin(paneID: draggedID, paneSize: .zero, cursor: .zero)
        let result = controller.end()
        #expect(result == nil)
        #expect(!controller.isDragging)
    }

    @Test func cancelResetsState() {
        let controller = PaneDragController()
        controller.begin(
            paneID: UUID(),
            paneSize: CGSize(width: 100, height: 100),
            cursor: CGPoint(x: 10, y: 10)
        )
        controller.cancel()
        #expect(!controller.isDragging)
        #expect(controller.cursorLocation == .zero)
    }
}
