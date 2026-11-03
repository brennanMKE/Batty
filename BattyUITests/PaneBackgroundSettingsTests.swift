// PaneBackgroundSettingsTests.swift

import XCTest

nonisolated final class PaneBackgroundSettingsTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
        BattyUITestHarness.sweepSentinels()
    }

    override func tearDownWithError() throws {
        BattyUITestHarness.sweepSentinels()
    }

    @MainActor
    private func gears(in app: XCUIApplication) -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'pane-background-settings.'"))
    }

    @MainActor
    private func eyes(in app: XCUIApplication) -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'pane-eye-toggle.'"))
    }

    @MainActor
    private func expandPaneList(in app: XCUIApplication) {
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        var disclosure = app.disclosureTriangles.firstMatch
        if !disclosure.waitForExistence(timeout: 5) {
            disclosure = app.descendants(matching: .disclosureTriangle).firstMatch
        }
        XCTAssertTrue(disclosure.waitForExistence(timeout: 5))
        disclosure.click()
        XCTAssertTrue(eyes(in: app).firstMatch.waitForExistence(timeout: 5))
    }

    @MainActor
    private func waitForValue(_ element: XCUIElement, _ expected: String) -> Bool {
        BattyUITestHarness.waitFor({ element.value as? String == expected }, timeout: 5, description: "value \(expected)")
    }

    @MainActor
    func testGearOpensSheetShowingFollowState() throws {
        let app = BattyUITestHarness.launchBatty()
        defer { app.terminate() }
        expandPaneList(in: app)

        gears(in: app).firstMatch.click()
        let follow = app.buttons["pane-background-sheet.follow"]
        XCTAssertTrue(follow.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForValue(follow, "selected"))
    }

    @MainActor
    func testCustomThenCancelReturnsToFollowing() throws {
        let app = BattyUITestHarness.launchBatty()
        defer { app.terminate() }
        expandPaneList(in: app)

        let gear = gears(in: app).firstMatch
        XCTAssertTrue(waitForValue(gear, "following"))
        gear.click()
        let custom = app.buttons["pane-background-sheet.custom"]
        XCTAssertTrue(custom.waitForExistence(timeout: 5))
        custom.click()
        XCTAssertTrue(waitForValue(gear, "custom"))
        app.buttons["pane-background-sheet.cancel"].click()
        XCTAssertTrue(waitForValue(gear, "following"))
    }

    @MainActor
    func testGearIsAbsentOnNonTerminalPane() throws {
        let app = BattyUITestHarness.launchBatty(script: [["intent": "createPane", "kind": "system-metrics"]])
        defer { app.terminate() }
        expandPaneList(in: app)

        XCTAssertTrue(BattyUITestHarness.waitFor({ self.eyes(in: app).count == 2 }, timeout: 5, description: "two rows"))
        XCTAssertEqual(gears(in: app).count, 1)
    }

    @MainActor
    func testGearIsAbsentWithTheFlagOff() throws {
        let app = BattyUITestHarness.launchBatty(
            script: [],
            extraEnvironment: ["BATTY_UI_TEST_FORCE_BACKGROUNDS_OFF": "1"]
        )
        defer { app.terminate() }
        expandPaneList(in: app)

        XCTAssertEqual(gears(in: app).count, 0)
    }
}
