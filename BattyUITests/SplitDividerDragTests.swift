// SplitDividerDragTests.swift

import XCTest

/// Regression coverage for [[0338]]: dragging a Split divider used to
/// jitter and jump back-and-forth instead of tracking the pointer, because
/// the drag gesture measured translation in the divider's own `.local`
/// coordinate space — a space that moves every time the divider is
/// repositioned mid-drag by `onRatioChange`. The fix roots the drag
/// gesture in a `.named` space anchored to the container `GeometryReader`
/// instead (see `SplitContainerView.swift`'s `SplitDividerMath` and
/// `BattyKitTests/SplitDividerMathTests.swift` for the pure-math coverage).
///
/// The divider itself carries no accessibility identifier — it is a bare
/// `Rectangle` (`DraggableSplitView.divider`) — so this test locates it as
/// the boundary between the two adjacent `pane-terminal.<uuid>` elements
/// and drives the drag from synthesized `XCUICoordinate`s. No other test
/// in this suite drags from a raw coordinate rather than element-to-element
/// (`DragDropTests.swift` drags a handle onto a target element), so this is
/// a new idiom here — kept to a single targeted test rather than a full
/// suite.
nonisolated final class SplitDividerDragTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testDraggingDividerRightMovesLeftPaneBoundaryMonotonically() throws {
        let app = BattyUITestHarness.launchBatty()
        defer { app.terminate() }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        app.typeKey("d", modifierFlags: [.command])
        let panes = panesQuery(in: app)
        XCTAssertTrue(waitFor({ panes.count >= 2 }, timeout: 5),
                      "Expected two panes after Cmd-D")

        let leftPane = panes.element(boundBy: 0)
        let rightPane = panes.element(boundBy: 1)
        XCTAssertTrue(leftPane.waitForExistence(timeout: 5))
        XCTAssertTrue(rightPane.waitForExistence(timeout: 5))

        let window = app.windows.firstMatch
        let windowOrigin = window.coordinate(withNormalizedOffset: .zero)
        func screenCoordinate(x: CGFloat, y: CGFloat) -> XCUICoordinate {
            windowOrigin.withOffset(CGVector(dx: x - window.frame.minX, dy: y - window.frame.minY))
        }

        let dividerY = leftPane.frame.midY
        var dividerX = (leftPane.frame.maxX + rightPane.frame.minX) / 2

        // Drag the divider rightward in several discrete steps, recording
        // the left pane's trailing edge (our proxy for the divider's
        // position, since the divider itself isn't accessibility-queryable)
        // after each step. Each step is its own complete press-drag
        // gesture with a fresh `startLocation`, so this sequence has
        // little power to reproduce the [[0338]] bug's actual mechanism —
        // translation collapsing back toward zero *within* a single
        // continuous gesture as the `.local` space moved under it (see
        // Gotchas). What it can still catch is a still-buggy divider
        // failing to reach each step's target, not just an unsmooth
        // animation.
        var boundaries: [CGFloat] = [leftPane.frame.maxX]
        let stepDistance: CGFloat = 30
        let steps = 3

        for _ in 0..<steps {
            let start = screenCoordinate(x: dividerX, y: dividerY)
            let targetX = dividerX + stepDistance
            let target = screenCoordinate(x: targetX, y: dividerY)
            start.press(forDuration: 0.05, thenDragTo: target)

            XCTAssertTrue(
                waitFor({ leftPane.frame.maxX > boundaries.last! + 1 }, timeout: 5),
                "Expected the divider (left pane's trailing edge) to move right after a drag step"
            )
            boundaries.append(leftPane.frame.maxX)
            dividerX = targetX
        }

        for (previous, next) in zip(boundaries, boundaries.dropFirst()) {
            XCTAssertGreaterThan(
                next, previous,
                "Divider moved backward between drag steps: \(boundaries) — each entry is sampled after its press-drag gesture completed, so this is regression in the divider's settled position across steps, not a mid-gesture observation"
            )
        }

        XCTAssertLessThan(
            abs(boundaries.last! - dividerX), 20,
            "Divider should end up near the pointer's final position, not resist/undershoot it"
        )
    }

    // MARK: - Helpers

    @MainActor
    private func panesQuery(in app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'pane-terminal.'"))
    }
}
