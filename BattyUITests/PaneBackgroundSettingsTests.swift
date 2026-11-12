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
    func testOpacitySlidersHaveLabels() throws {
        let app = BattyUITestHarness.launchBatty()
        defer { app.terminate() }
        expandPaneList(in: app)

        gears(in: app).firstMatch.click()
        let custom = app.buttons["pane-background-sheet.custom"]
        XCTAssertTrue(custom.waitForExistence(timeout: 5))
        custom.click()
        let image = app.sliders["pane-background-sheet.image-opacity"]
        let terminal = app.sliders["pane-background-sheet.terminal-opacity"]
        XCTAssertTrue(image.waitForExistence(timeout: 5))
        XCTAssertEqual(image.label, "Image Opacity")
        XCTAssertEqual(terminal.label, "Terminal Opacity")
    }
    // MARK: - Tab chip

    @MainActor
    private func openTabBackgroundSheet(in app: XCUIApplication) {
        let chip = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'tab-chip.'")).firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 10), "no Tab chip")
        chip.rightClick()
        let item = app.menuItems["Background\u{2026}"]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "the Tab chip menu has no Background…")
        item.click()
    }

    @MainActor
    func testTabChipMenuOpensTabBackgroundSheet() throws {
        let app = BattyUITestHarness.launchBatty()
        defer { app.terminate() }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        openTabBackgroundSheet(in: app)
        let follow = app.buttons["tab-background-sheet.follow"]
        XCTAssertTrue(follow.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForValue(follow, "selected"))
        app.buttons["tab-background-sheet.cancel"].click()
    }

    @MainActor
    func testClearBackgroundIsDisabledWithoutATabValue() throws {
        let app = BattyUITestHarness.launchBatty()
        defer { app.terminate() }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        let chip = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'tab-chip.'")).firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 10), "no Tab chip")
        chip.rightClick()
        let clear = app.menuItems["Clear Background"]
        XCTAssertTrue(clear.waitForExistence(timeout: 5), "the Tab chip menu has no Clear Background")
        XCTAssertFalse(clear.isEnabled)
        app.typeKey(.escape, modifierFlags: [])
    }

    @MainActor
    func testPaneGearReplacesATabsOwnBackground() throws {
        let app = BattyUITestHarness.launchBatty()
        defer { app.terminate() }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        openTabBackgroundSheet(in: app)
        let tabCustom = app.buttons["tab-background-sheet.custom"]
        XCTAssertTrue(tabCustom.waitForExistence(timeout: 5))
        tabCustom.click()
        app.buttons["tab-background-sheet.done"].click()

        expandPaneList(in: app)
        gears(in: app).firstMatch.click()
        let paneCustom = app.buttons["pane-background-sheet.custom"]
        XCTAssertTrue(paneCustom.waitForExistence(timeout: 5))
        paneCustom.click()
        app.buttons["pane-background-sheet.done"].click()

        openTabBackgroundSheet(in: app)
        let follow = app.buttons["tab-background-sheet.follow"]
        XCTAssertTrue(follow.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForValue(follow, "selected"), "the Pane gear did not replace the Tab's own background")
        app.buttons["tab-background-sheet.cancel"].click()
    }
}
