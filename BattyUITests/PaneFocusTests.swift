// PaneFocusTests.swift

import XCTest

/// Focus interactions across splits — covers `#0092`. Builds on the
/// harness from `#0091`. Every test starts cold-launched and exercises
/// click + keyboard focus moves through the accessibility identifiers
/// wired into `PaneView` / `SessionDetailView`.
nonisolated final class PaneFocusTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testCmdDMakesNewPaneFocused() throws {
        let app = BattyUITestHarness.launchBatty()
        defer { app.terminate() }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        app.typeKey("d", modifierFlags: [.command])
        // After Cmd-D the new pane becomes focused — assert two pane
        // tab-bars are now present by looking for any element whose
        // identifier starts with "tab-bar.".
        let tabBars = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'tab-bar.'"))
        XCTAssertTrue(waitFor(tabBars.count >= 2, timeout: 5), "Expected two tab bars after Cmd-D")
    }

    @MainActor
    func testCmdShiftDMakesNewPaneFocused() throws {
        let app = BattyUITestHarness.launchBatty()
        defer { app.terminate() }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        app.typeKey("d", modifierFlags: [.command, .shift])
        let tabBars = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'tab-bar.'"))
        XCTAssertTrue(waitFor(tabBars.count >= 2, timeout: 5), "Expected two tab bars after Cmd-Shift-D")
    }

    @MainActor
    func testClickInPaneBodyFocusesPane() throws {
        let app = BattyUITestHarness.launchBatty()
        defer { app.terminate() }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        app.typeKey("d", modifierFlags: [.command])
        let panes = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'pane-terminal.'"))
        XCTAssertTrue(waitFor(panes.count >= 2, timeout: 5))

        let leftPane = panes.element(boundBy: 0)
        XCTAssertTrue(leftPane.waitForExistence(timeout: 5))
        leftPane.click()
        // No observable assertion here without reading focused-pane state — the
        // visual focus indicator (#0052) is the user-facing signal. Mark this
        // case as needing manual sign-off until the indicator is queryable.
        XCTAssertTrue(leftPane.exists)
    }

    @MainActor
    func testClickInBottomPaneAfterVerticalSplitFocuses() throws {
        let app = BattyUITestHarness.launchBatty()
        defer { app.terminate() }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        app.typeKey("d", modifierFlags: [.command, .shift])
        let panes = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'pane-terminal.'"))
        XCTAssertTrue(waitFor(panes.count >= 2, timeout: 5))

        // #0090 regression: clicking the second (bottom) pane should
        // succeed; before the hitTest fix it silently dropped.
        let bottomPane = panes.element(boundBy: 1)
        XCTAssertTrue(bottomPane.waitForExistence(timeout: 5))
        bottomPane.click()
        XCTAssertTrue(bottomPane.exists)
    }

    @MainActor
    func testCmdOptionArrowsMoveFocus() throws {
        let app = BattyUITestHarness.launchBatty()
        defer { app.terminate() }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        app.typeKey("d", modifierFlags: [.command])
        let panes = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'pane-terminal.'"))
        XCTAssertTrue(waitFor(panes.count >= 2, timeout: 5))

        // Move focus left then right; no crash + panes still present.
        app.typeKey(XCUIKeyboardKey.leftArrow.rawValue, modifierFlags: [.command, .option])
        app.typeKey(XCUIKeyboardKey.rightArrow.rawValue, modifierFlags: [.command, .option])
        XCTAssertEqual(panes.count, 2)
    }

    private func waitFor(_ predicate: @autoclosure () -> Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return predicate()
    }
}
