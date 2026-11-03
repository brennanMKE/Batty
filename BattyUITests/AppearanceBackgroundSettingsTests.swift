// AppearanceBackgroundSettingsTests.swift

import XCTest

nonisolated final class AppearanceBackgroundSettingsTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
        BattyUITestHarness.sweepSentinels()
    }

    override func tearDownWithError() throws {
        BattyUITestHarness.sweepSentinels()
    }

    @MainActor
    private func openAppearanceSettings(in app: XCUIApplication) {
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        app.typeKey(",", modifierFlags: [.command])
        let appearance = app.toolbars.buttons["Appearance"]
        XCTAssertTrue(appearance.waitForExistence(timeout: 10))
        appearance.click()
    }

    @MainActor
    func testBackgroundControlsAppearInAppearanceSettings() throws {
        let app = BattyUITestHarness.launchBatty()
        defer { app.terminate() }
        openAppearanceSettings(in: app)

        XCTAssertTrue(app.buttons["appearance-background.restore-defaults"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["appearance-background.choose-image"].exists)
    }

    @MainActor
    func testOpacityFieldsAcceptTypedValuesAndClamp() throws {
        let app = BattyUITestHarness.launchBatty()
        defer { app.terminate() }
        openAppearanceSettings(in: app)

        let restore = app.buttons["appearance-background.restore-defaults"]
        XCTAssertTrue(restore.waitForExistence(timeout: 5))
        restore.click()

        let terminal = app.textFields["appearance-background.terminal-opacity-field"]
        let image = app.textFields["appearance-background.image-opacity-field"]
        XCTAssertTrue(terminal.waitForExistence(timeout: 5))
        XCTAssertEqual(terminal.label, "Terminal Opacity Percent")
        XCTAssertEqual(image.label, "Image Opacity Percent")
        XCTAssertTrue(terminal.isEnabled)
        XCTAssertFalse(image.isEnabled)
        XCTAssertEqual(terminal.value as? String, "100")

        terminal.click()
        terminal.typeKey("a", modifierFlags: [.command])
        terminal.typeText("150\n")
        XCTAssertEqual(terminal.value as? String, "100")

        terminal.typeKey("a", modifierFlags: [.command])
        terminal.typeText("37\n")
        XCTAssertEqual(terminal.value as? String, "37")

        terminal.typeKey("a", modifierFlags: [.command])
        terminal.typeText("abc\n")
        XCTAssertEqual(terminal.value as? String, "37")

        restore.click()
    }

    @MainActor
    func testBackgroundControlsAbsentWithTheFlagOff() throws {
        let app = BattyUITestHarness.launchBatty(
            script: [],
            extraEnvironment: ["BATTY_UI_TEST_FORCE_BACKGROUNDS_OFF": "1"]
        )
        defer { app.terminate() }
        openAppearanceSettings(in: app)

        XCTAssertFalse(app.buttons["appearance-background.restore-defaults"].waitForExistence(timeout: 2))
    }
}
