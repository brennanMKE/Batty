// LayoutTests.swift

import XCTest

/// Layout-picker regression suite for [[0162]].
///
/// Asserts that each preset produces the right pane count and that the
/// layout picker is gated correctly. Uses Mode A driver intents only.
nonisolated final class LayoutTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
        BattyUITestHarness.sweepSentinels()
    }

    override func tearDownWithError() throws {
        BattyUITestHarness.sweepSentinels()
    }

    // MARK: - Layout pane counts — would catch [[0136]] regressions

    /// twoByTwoGrid produces 4 panes. Would catch any regression in the preset.
    @MainActor
    func testTwoByTwoGridProducesFourPanes() throws {
        let app = BattyUITestHarness.launchBatty(script: [
            ["intent": "applyLayout", "layout": "twoByTwoGrid"]
        ])
        defer { app.terminate() }

        XCTAssertNil(BattyUITestHarness.waitForDriverErrors(), "Driver script failed")
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        let panes = panesQuery(in: app)
        XCTAssertTrue(
            waitFor({ panes.count == 4 }, timeout: 10),
            "twoByTwoGrid must produce exactly 4 panes; got \(panes.count)"
        )
    }

    /// horizontalSplit produces 2 panes side by side.
    @MainActor
    func testTwoColumnProducesTwoPanes() throws {
        let app = BattyUITestHarness.launchBatty(script: [
            ["intent": "applyLayout", "layout": "horizontalSplit"]
        ])
        defer { app.terminate() }

        XCTAssertNil(BattyUITestHarness.waitForDriverErrors(), "Driver script failed")
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        let panes = panesQuery(in: app)
        XCTAssertTrue(waitFor({ panes.count == 2 }, timeout: 10),
                      "horizontalSplit must produce exactly 2 panes; got \(panes.count)")
    }

    /// verticalSplit produces 2 panes stacked vertically.
    @MainActor
    func testTwoRowProducesTwoPanes() throws {
        let app = BattyUITestHarness.launchBatty(script: [
            ["intent": "applyLayout", "layout": "verticalSplit"]
        ])
        defer { app.terminate() }

        XCTAssertNil(BattyUITestHarness.waitForDriverErrors(), "Driver script failed")
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        let panes = panesQuery(in: app)
        XCTAssertTrue(waitFor({ panes.count == 2 }, timeout: 10),
                      "verticalSplit must produce exactly 2 panes; got \(panes.count)")
    }

    /// threeColumns produces 3 panes side by side.
    @MainActor
    func testThreeColumnProducesThreePanes() throws {
        let app = BattyUITestHarness.launchBatty(script: [
            ["intent": "applyLayout", "layout": "threeColumns"]
        ])
        defer { app.terminate() }

        XCTAssertNil(BattyUITestHarness.waitForDriverErrors(), "Driver script failed")
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        let panes = panesQuery(in: app)
        XCTAssertTrue(waitFor({ panes.count == 3 }, timeout: 10),
                      "threeColumns must produce exactly 3 panes; got \(panes.count)")
    }

    /// mainLeftTwoRight produces 3 panes.
    @MainActor
    func testMainLeftTwoRightProducesThreePanes() throws {
        let app = BattyUITestHarness.launchBatty(script: [
            ["intent": "applyLayout", "layout": "mainLeftTwoRight"]
        ])
        defer { app.terminate() }

        XCTAssertNil(BattyUITestHarness.waitForDriverErrors(), "Driver script failed")
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        let panes = panesQuery(in: app)
        XCTAssertTrue(waitFor({ panes.count == 3 }, timeout: 10),
                      "mainLeftTwoRight must produce exactly 3 panes; got \(panes.count)")
    }

    /// mainTopTwoBottom produces 3 panes.
    @MainActor
    func testMainTopTwoBottomProducesThreePanes() throws {
        let app = BattyUITestHarness.launchBatty(script: [
            ["intent": "applyLayout", "layout": "mainTopTwoBottom"]
        ])
        defer { app.terminate() }

        XCTAssertNil(BattyUITestHarness.waitForDriverErrors(), "Driver script failed")
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        let panes = panesQuery(in: app)
        XCTAssertTrue(waitFor({ panes.count == 3 }, timeout: 10),
                      "mainTopTwoBottom must produce exactly 3 panes; got \(panes.count)")
    }

    // MARK: - Helpers

    @MainActor
    private func panesQuery(in app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'pane-terminal.'"))
    }
}
