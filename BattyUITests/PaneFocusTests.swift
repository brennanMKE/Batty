// PaneFocusTests.swift

import XCTest

/// Focus interactions across splits — covers `#0092`. Builds on the
/// harness from `#0091`. Every test starts cold-launched and exercises
/// click + keyboard focus moves through the accessibility identifiers
/// wired into `PaneView` / `SessionDetailView`.
///
/// Focus state is read off the per-pane accessibility value:
/// `"focused"` or `"unfocused"`. `PaneView` sets that value from
/// `isPaneFocused`, which is driven by `tree.focusedPaneID`. That lets
/// these tests assert the model-side outcome rather than just "the
/// click landed without crashing."
nonisolated final class PaneFocusTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Split-creates-focused-pane

    @MainActor
    func testCmdDFocusesNewPane() throws {
        let app = BattyUITestHarness.launchBatty()
        defer { app.terminate() }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        app.typeKey("d", modifierFlags: [.command])
        let panes = panesQuery(in: app)
        XCTAssertTrue(waitFor({ panes.count >= 2 }, timeout: 5),
                      "Expected two panes after Cmd-D")
        // After Cmd-D the NEW pane becomes focused. Layout convention:
        // `.horizontal` is an HStack — original on the left, new on the right.
        XCTAssertTrue(waitFor({ self.focusedIndex(in: app) == 1 }, timeout: 5),
                      "Expected the new (right) pane to be focused after Cmd-D")
    }

    @MainActor
    func testCmdShiftDFocusesNewPane() throws {
        let app = BattyUITestHarness.launchBatty()
        defer { app.terminate() }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        app.typeKey("d", modifierFlags: [.command, .shift])
        let panes = panesQuery(in: app)
        XCTAssertTrue(waitFor({ panes.count >= 2 }, timeout: 5),
                      "Expected two panes after Cmd-Shift-D")
        // `.vertical` is a VStack — original on top, new on the bottom.
        XCTAssertTrue(waitFor({ self.focusedIndex(in: app) == 1 }, timeout: 5),
                      "Expected the new (bottom) pane to be focused after Cmd-Shift-D")
    }

    // MARK: - Click-to-focus, horizontal split (left/right)

    @MainActor
    func testClickInLeftPaneAfterHorizontalSplitFocusesIt() throws {
        let app = BattyUITestHarness.launchBatty()
        defer { app.terminate() }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        app.typeKey("d", modifierFlags: [.command])
        let panes = panesQuery(in: app)
        XCTAssertTrue(waitFor({ panes.count >= 2 }, timeout: 5))
        XCTAssertTrue(waitFor({ self.focusedIndex(in: app) == 1 }, timeout: 5),
                      "Cmd-D should focus the new (right) pane first")

        panes.element(boundBy: 0).click()
        XCTAssertTrue(waitFor({ self.focusedIndex(in: app) == 0 }, timeout: 5),
                      "Click in left pane should move focus to it")
    }

    @MainActor
    func testClickInRightPaneAfterHorizontalSplitFocusesIt() throws {
        let app = BattyUITestHarness.launchBatty()
        defer { app.terminate() }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        app.typeKey("d", modifierFlags: [.command])
        let panes = panesQuery(in: app)
        XCTAssertTrue(waitFor({ panes.count >= 2 }, timeout: 5))

        // Start by clicking left so focus is in a known non-right state.
        panes.element(boundBy: 0).click()
        XCTAssertTrue(waitFor({ self.focusedIndex(in: app) == 0 }, timeout: 5))

        panes.element(boundBy: 1).click()
        XCTAssertTrue(waitFor({ self.focusedIndex(in: app) == 1 }, timeout: 5),
                      "Click in right pane should move focus to it")
    }

    // MARK: - Click-to-focus, vertical split (top/bottom)

    @MainActor
    func testClickInTopPaneAfterVerticalSplitFocusesIt() throws {
        let app = BattyUITestHarness.launchBatty()
        defer { app.terminate() }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        app.typeKey("d", modifierFlags: [.command, .shift])
        let panes = panesQuery(in: app)
        XCTAssertTrue(waitFor({ panes.count >= 2 }, timeout: 5))
        XCTAssertTrue(waitFor({ self.focusedIndex(in: app) == 1 }, timeout: 5),
                      "Cmd-Shift-D should focus the new (bottom) pane first")

        panes.element(boundBy: 0).click()
        XCTAssertTrue(waitFor({ self.focusedIndex(in: app) == 0 }, timeout: 5),
                      "Click in top pane should move focus to it")
    }

    @MainActor
    func testClickInBottomPaneAfterVerticalSplitFocusesIt() throws {
        // #0090 regression: bottom-pane click after vertical split silently
        // dropped before the TerminalHostView.hitTest simplification.
        let app = BattyUITestHarness.launchBatty()
        defer { app.terminate() }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        app.typeKey("d", modifierFlags: [.command, .shift])
        let panes = panesQuery(in: app)
        XCTAssertTrue(waitFor({ panes.count >= 2 }, timeout: 5))

        // Move focus to the top pane so the bottom-pane click has work to do.
        panes.element(boundBy: 0).click()
        XCTAssertTrue(waitFor({ self.focusedIndex(in: app) == 0 }, timeout: 5))

        panes.element(boundBy: 1).click()
        XCTAssertTrue(waitFor({ self.focusedIndex(in: app) == 1 }, timeout: 5),
                      "Click in bottom pane should move focus to it (#0090)")
    }

    // MARK: - Geometric movement

    @MainActor
    func testCmdOptionArrowsMoveFocusAcrossHorizontalSplit() throws {
        let app = BattyUITestHarness.launchBatty()
        defer { app.terminate() }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        app.typeKey("d", modifierFlags: [.command])
        let panes = panesQuery(in: app)
        XCTAssertTrue(waitFor({ panes.count >= 2 }, timeout: 5))
        // Right pane focused after the split.
        XCTAssertTrue(waitFor({ self.focusedIndex(in: app) == 1 }, timeout: 5))

        app.typeKey(XCUIKeyboardKey.leftArrow.rawValue, modifierFlags: [.command, .option])
        XCTAssertTrue(waitFor({ self.focusedIndex(in: app) == 0 }, timeout: 5),
                      "Cmd-Option-Left should focus the left pane")

        app.typeKey(XCUIKeyboardKey.rightArrow.rawValue, modifierFlags: [.command, .option])
        XCTAssertTrue(waitFor({ self.focusedIndex(in: app) == 1 }, timeout: 5),
                      "Cmd-Option-Right should focus the right pane")
    }

    @MainActor
    func testCmdOptionArrowsMoveFocusAcrossVerticalSplit() throws {
        let app = BattyUITestHarness.launchBatty()
        defer { app.terminate() }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        app.typeKey("d", modifierFlags: [.command, .shift])
        let panes = panesQuery(in: app)
        XCTAssertTrue(waitFor({ panes.count >= 2 }, timeout: 5))
        // Bottom pane focused after the split.
        XCTAssertTrue(waitFor({ self.focusedIndex(in: app) == 1 }, timeout: 5))

        app.typeKey(XCUIKeyboardKey.upArrow.rawValue, modifierFlags: [.command, .option])
        XCTAssertTrue(waitFor({ self.focusedIndex(in: app) == 0 }, timeout: 5),
                      "Cmd-Option-Up should focus the top pane")

        app.typeKey(XCUIKeyboardKey.downArrow.rawValue, modifierFlags: [.command, .option])
        XCTAssertTrue(waitFor({ self.focusedIndex(in: app) == 1 }, timeout: 5),
                      "Cmd-Option-Down should focus the bottom pane")
    }

    // MARK: - Helpers

    @MainActor
    private func panesQuery(in app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'pane-terminal.'"))
    }

    /// Index of the focused pane in `panesQuery` iteration order, or `nil`
    /// when no pane reports `focused`. PaneView sets `accessibilityValue`
    /// to `"focused"` / `"unfocused"` from `isPaneFocused`.
    @MainActor
    private func focusedIndex(in app: XCUIApplication) -> Int? {
        let panes = panesQuery(in: app)
        for i in 0..<panes.count {
            if (panes.element(boundBy: i).value as? String) == "focused" {
                return i
            }
        }
        return nil
    }

    private func waitFor(_ predicate: @escaping () -> Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return predicate()
    }
}
