// NonTerminalPaneCloseTests.swift

import XCTest

nonisolated final class NonTerminalPaneCloseTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
        BattyUITestHarness.sweepSentinels()
    }

    override func tearDownWithError() throws {
        BattyUITestHarness.sweepSentinels()
    }

    @MainActor
    func testCloseButtonClosesNonTerminalPaneAndCollapsesSplit() throws {
        let app = BattyUITestHarness.launchBatty(script: [
            ["intent": "createPane", "kind": "system-metrics"]
        ])
        defer { app.terminate() }

        XCTAssertNil(BattyUITestHarness.waitForDriverErrors(), "Driver script failed")
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        let closeButton = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'pane-close-button.'")
        ).firstMatch
        XCTAssertTrue(closeButton.waitForExistence(timeout: 5))
        XCTAssertEqual(closeButton.label, "Close pane")

        let paneID = String(closeButton.identifier.dropFirst("pane-close-button.".count))
        let eyeButton = app.buttons["pane-eye-button.\(paneID)"]
        XCTAssertTrue(eyeButton.waitForExistence(timeout: 5))
        XCTAssertLessThan(closeButton.frame.midX, eyeButton.frame.midX,
                          "The close X must sit opposite the visibility eye")

        // Review round 1 (#0378): a bare post-close count of
        // `pane-terminal.` elements is satisfied by the *initial* state
        // too (one terminal Pane exists before the click, since
        // `createPane` only adds the non-terminal sibling) -- it would
        // still pass if the Split never collapsed, if the Pane were only
        // hidden, or if the terminal sibling never grew. Capturing the
        // terminal sibling's own frame before the click and requiring it
        // to grow afterward actually exercises "the Split collapses and
        // the sibling absorbs the freed space," matching the frame-growth
        // idiom `SplitDividerDragTests.swift` already uses against these
        // same `pane-terminal.` elements.
        let terminalPane = panesQuery(in: app).firstMatch
        XCTAssertTrue(terminalPane.waitForExistence(timeout: 5))
        let areaBeforeClose = terminalPane.frame.width * terminalPane.frame.height

        closeButton.click()

        XCTAssertTrue(waitFor({ !closeButton.exists }, timeout: 5),
                      "Closing the non-terminal Pane must remove its shared header")
        XCTAssertTrue(
            waitFor({ terminalPane.frame.width * terminalPane.frame.height > areaBeforeClose + 1 }, timeout: 5),
            "The terminal sibling must absorb the collapsed Split by growing into the freed space"
        )
    }

    // MARK: - Helpers

    @MainActor
    private func panesQuery(in app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'pane-terminal.'"))
    }
}
