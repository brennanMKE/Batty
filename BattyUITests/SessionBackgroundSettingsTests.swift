// SessionBackgroundSettingsTests.swift

import XCTest

nonisolated final class SessionBackgroundSettingsTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
        BattyUITestHarness.sweepSentinels()
    }

    override func tearDownWithError() throws {
        BattyUITestHarness.sweepSentinels()
    }

    @MainActor
    private func menuItem(_ prefix: String, in app: XCUIApplication) -> XCUIElement {
        app.menuItems.matching(NSPredicate(format: "title BEGINSWITH %@", prefix)).firstMatch
    }

    @MainActor
    private func openSheet(in app: XCUIApplication) {
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        BattyUITestHarness.sessionRow(named: "Session 1", in: app).rightClick()
        let set = menuItem("Set Session Background", in: app)
        XCTAssertTrue(set.waitForExistence(timeout: 5))
        set.click()
    }

    @MainActor
    private func waitForValue(_ element: XCUIElement, _ expected: String) -> Bool {
        BattyUITestHarness.waitFor({ element.value as? String == expected }, timeout: 5, description: "value \(expected)")
    }

    @MainActor
    func testContextMenuOpensSheetShowingFollowState() throws {
        let app = BattyUITestHarness.launchBatty()
        defer { app.terminate() }
        openSheet(in: app)

        let follow = app.buttons["session-background-sheet.follow"]
        XCTAssertTrue(follow.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForValue(follow, "selected"))
    }

    @MainActor
    func testCustomThenCancelReturnsToFollowing() throws {
        let app = BattyUITestHarness.launchBatty()
        defer { app.terminate() }
        openSheet(in: app)

        let custom = app.buttons["session-background-sheet.custom"]
        XCTAssertTrue(custom.waitForExistence(timeout: 5))
        custom.click()
        XCTAssertTrue(waitForValue(custom, "selected"))
        app.buttons["session-background-sheet.cancel"].click()

        openSheet(in: app)
        let follow = app.buttons["session-background-sheet.follow"]
        XCTAssertTrue(follow.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForValue(follow, "selected"))
    }

    @MainActor
    func testClearItemAppearsOnlyWithAnOverride() throws {
        let app = BattyUITestHarness.launchBatty()
        defer { app.terminate() }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        let row = BattyUITestHarness.sessionRow(named: "Session 1", in: app)

        row.rightClick()
        let set = menuItem("Set Session Background", in: app)
        XCTAssertTrue(set.waitForExistence(timeout: 5))
        XCTAssertFalse(menuItem("Clear Session Background", in: app).exists)
        set.click()

        let custom = app.buttons["session-background-sheet.custom"]
        XCTAssertTrue(custom.waitForExistence(timeout: 5))
        custom.click()
        XCTAssertTrue(waitForValue(custom, "selected"))
        app.buttons["session-background-sheet.done"].click()

        row.rightClick()
        let clear = menuItem("Clear Session Background", in: app)
        XCTAssertTrue(clear.waitForExistence(timeout: 5))
        clear.click()

        row.rightClick()
        XCTAssertTrue(menuItem("Set Session Background", in: app).waitForExistence(timeout: 5))
        XCTAssertFalse(menuItem("Clear Session Background", in: app).exists)
    }
}
