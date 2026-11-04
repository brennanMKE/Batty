// TerminalSeeThroughTests.swift

import XCTest

/// Clicks through the real window server, because a non-opaque window could
/// pass a click on before it ever reaches `TerminalHostView.hitTest`.
nonisolated final class TerminalSeeThroughTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
        BattyUITestHarness.sweepSentinels()
    }

    override func tearDownWithError() throws {
        BattyUITestHarness.sweepSentinels()
    }

    @MainActor
    func testClickAtZeroOpacityFocusesThePaneUnderIt() throws {
        let app = BattyUITestHarness.launchBatty()
        defer { app.terminate() }
        splitIntoTwoPanes(in: app)

        withSettings(in: app) { setTerminalOpacity("0", in: app) }
        attachScreenshot(named: "zero-opacity")

        clickLeftPaneAndExpectFocus(in: app, "A click at opacity 0 should focus the Pane under it")

        withSettings(in: app) { app.buttons["appearance-background.restore-defaults"].click() }
    }

    @MainActor
    func testBackToFullOpacityKeepsClickingWorking() throws {
        let app = BattyUITestHarness.launchBatty()
        defer { app.terminate() }
        splitIntoTwoPanes(in: app)

        withSettings(in: app) {
            setTerminalOpacity("0", in: app)
            app.buttons["appearance-background.restore-defaults"].click()
        }

        clickLeftPaneAndExpectFocus(in: app, "A click after returning to full opacity should focus the Pane under it")
    }

    // MARK: - Helpers

    @MainActor
    private func panes(in app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'pane-terminal.'"))
    }

    @MainActor
    private func splitIntoTwoPanes(in app: XCUIApplication) {
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        app.typeKey("d", modifierFlags: [.command])
        let panes = panes(in: app)
        XCTAssertTrue(BattyUITestHarness.waitFor({ panes.count == 2 }, timeout: 5, description: "two Panes"))
        XCTAssertTrue(BattyUITestHarness.waitFor(
            { panes.element(boundBy: 1).label == "focused" },
            timeout: 5,
            description: "the new Pane focused"
        ))
    }

    @MainActor
    private func withSettings(in app: XCUIApplication, _ body: () -> Void) {
        app.typeKey(",", modifierFlags: [.command])
        let appearance = app.toolbars.buttons["Appearance"]
        XCTAssertTrue(appearance.waitForExistence(timeout: 10))
        appearance.click()
        XCTAssertTrue(app.buttons["appearance-background.restore-defaults"].waitForExistence(timeout: 5))
        body()
        app.typeKey("w", modifierFlags: [.command])
        XCTAssertTrue(appearance.waitForNonExistence(timeout: 5))
    }

    @MainActor
    private func setTerminalOpacity(_ value: String, in app: XCUIApplication) {
        let field = app.textFields["appearance-background.terminal-opacity-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.click()
        field.typeKey("a", modifierFlags: [.command])
        field.typeText("\(value)\n")
        XCTAssertEqual(field.value as? String, value)
    }

    @MainActor
    private func clickLeftPaneAndExpectFocus(in app: XCUIApplication, _ message: String) {
        let panes = panes(in: app)
        panes.element(boundBy: 0).click()
        XCTAssertTrue(
            BattyUITestHarness.waitFor({ panes.element(boundBy: 0).label == "focused" }, timeout: 5, description: "left Pane focused"),
            message
        )
    }

    @MainActor
    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
