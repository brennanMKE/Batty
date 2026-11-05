// TerminalSeeThroughTests.swift

import XCTest

/// Clicks and drags through the real window server, because a non-opaque window
/// could pass a press on before it ever reaches `TerminalHostView.hitTest`.
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

    // MARK: - Window chrome below full opacity

    @MainActor
    func testTitleBarOverTheTerminalDragsTheWindowBelowFullOpacity() throws {
        runWithOpacity("80", theme: Self.noTheme) { app in
            assertTitleBarOverTheTerminalDragsTheWindow(in: app)
        }
    }

    @MainActor
    func testTitleBarOverTheTerminalDragsTheWindowBelowFullOpacityWithATheme() throws {
        runWithOpacity("80", theme: Self.theme) { app in
            assertTitleBarOverTheTerminalDragsTheWindow(in: app)
        }
    }

    @MainActor
    func testTitleBarDragsTheWindowFromTitleHeightBelowFullOpacity() throws {
        runWithOpacity("80", theme: Self.noTheme) { app in
            assertDragMovesWindow(from: titleHeightPoint(in: app), in: app)
        }
    }

    @MainActor
    func testTitleBarDragsTheWindowFromTitleHeightBelowFullOpacityWithATheme() throws {
        runWithOpacity("80", theme: Self.theme) { app in
            assertDragMovesWindow(from: titleHeightPoint(in: app), in: app)
        }
    }

    @MainActor
    func testTitleBarOverTheTerminalDragsTheWindowAtFullOpacity() throws {
        runWithOpacity(nil, theme: Self.noTheme) { app in
            assertTitleBarOverTheTerminalDragsTheWindow(in: app)
        }
    }

    @MainActor
    func testTitleBarOverTheTerminalDragsTheWindowAtFullOpacityWithATheme() throws {
        runWithOpacity(nil, theme: Self.theme) { app in
            assertTitleBarOverTheTerminalDragsTheWindow(in: app)
        }
    }

    @MainActor
    func testTitleBarOverTheSidebarDragsTheWindowBelowFullOpacity() throws {
        runWithOpacity("80", theme: Self.noTheme) { app in
            let window = app.windows.firstMatch
            let x = window.frame.minX + 120
            XCTAssertLessThan(x, firstPane(in: app).frame.minX, "The point must be over the Sidebar")
            assertDragMovesWindow(from: titleBarPoint(x: x, in: app), in: app)
        }
    }

    @MainActor
    func testTitleBarOverTheTerminalDragsTheWindowAtZeroOpacity() throws {
        runWithOpacity("0", theme: Self.noTheme) { app in
            assertTitleBarOverTheTerminalDragsTheWindow(in: app)
        }
    }

    @MainActor
    func testTitleBarDragsTheWindowBelowFullOpacityWithTheSidebarCollapsed() throws {
        runWithOpacity("80", theme: Self.noTheme) { app in
            collapseSidebar(in: app)
            assertTitleBarOverTheTerminalDragsTheWindow(in: app)
        }
    }

    @MainActor
    func testTitleBarDoubleClickZoomsTheWindowBelowFullOpacity() throws {
        try skipUnlessDoubleClickZooms()
        runWithOpacity("80", theme: Self.noTheme) { app in
            assertDoubleClickZoomsWindow(at: titleBarPoint(x: firstPane(in: app).frame.midX, in: app), in: app)
        }
    }

    @MainActor
    func testTitleBarDoubleClickFromTitleHeightZoomsTheWindowBelowFullOpacity() throws {
        try skipUnlessDoubleClickZooms()
        runWithOpacity("80", theme: Self.noTheme) { app in
            assertDoubleClickZoomsWindow(at: titleHeightPoint(in: app), in: app)
        }
    }

    @MainActor
    func testMinimizeButtonWorksBelowFullOpacityWithTheSidebarCollapsed() throws {
        runWithOpacity("80", theme: Self.noTheme) { app in
            collapseSidebar(in: app)
            let window = app.windows.firstMatch
            window.buttons[XCUIIdentifierMinimizeWindow].click()
            XCTAssertTrue(
                BattyUITestHarness.waitFor({ !window.isHittable }, timeout: 10, description: "the window to minimize"),
                "The minimize button should minimize the window"
            )
        }
    }

    @MainActor
    func testToolbarButtonWorksBelowFullOpacity() throws {
        runWithOpacity("80", theme: Self.noTheme) { app in
            let button = app.descendants(matching: .any).matching(identifier: "toolbar.split-horizontal").firstMatch
            XCTAssertTrue(button.waitForExistence(timeout: 5))
            button.click()
            let panes = panes(in: app)
            XCTAssertTrue(
                BattyUITestHarness.waitFor({ panes.count == 2 }, timeout: 5, description: "two Panes"),
                "The toolbar's split button should split the Pane"
            )
        }
    }

    @MainActor
    func testTabChipClickWorksBelowFullOpacity() throws {
        let script: [[String: Any]] = [
            ["intent": "renameActiveTab", "to": "TabAlpha"],
            ["intent": "createTab"],
            ["intent": "renameActiveTab", "to": "TabBeta"]
        ]
        runWithOpacity("80", theme: Self.noTheme, script: script) { app in
            XCTAssertNil(BattyUITestHarness.waitForDriverErrors(), "Driver script failed")
            let chip = app.descendants(matching: .any).matching(identifier: "tab-chip.TabAlpha").firstMatch
            XCTAssertTrue(chip.waitForExistence(timeout: 5))
            chip.click()
            XCTAssertTrue(
                BattyUITestHarness.waitFor({ chip.value as? String == "active" }, timeout: 5, description: "TabAlpha active"),
                "Clicking a tab chip should activate its Tab"
            )
        }
    }

    @MainActor
    func testDragInsideTheTerminalDoesNotMoveTheWindowBelowFullOpacity() throws {
        runWithOpacity("80", theme: Self.noTheme) { app in
            let window = app.windows.firstMatch
            let pane = firstPane(in: app).frame
            let before = window.frame
            screenPoint(x: pane.midX, y: pane.midY, in: app)
                .press(forDuration: 0.2, thenDragTo: screenPoint(x: pane.midX + Self.dragDistance, y: pane.midY + Self.dragDistance, in: app))
            let moved = BattyUITestHarness.waitFor({ window.frame != before }, timeout: 2, description: "the window to move")
            XCTAssertFalse(moved, "A drag inside a terminal must not move the window, frame went from \(before) to \(window.frame)")
        }
    }

    // MARK: - Helpers

    /// Launch arguments outrank anything stored, so a Theme can't leak between
    /// tests. A fresh install seeds `ThemePreference.defaultDarkThemeName`, so
    /// a plain launch has a Theme; a name outside the catalog resolves to none.
    private static let noTheme = "NoSuchTheme"
    private static let theme = "Dracula"
    private static let dragDistance: CGFloat = 60
    private static let dragTolerance: CGFloat = 8

    private func themeArguments(_ name: String) -> [String] {
        [
            "-co.sstools.Batty.themeName.dark", name,
            "-co.sstools.Batty.themeName.light", name
        ]
    }

    /// `opacity` of `nil` leaves Settings alone, the state of a user who never
    /// opened them. Assertions in `body` don't stop the test, so Terminal
    /// Opacity is restored and one failure can't change the next test's state.
    @MainActor
    private func runWithOpacity(
        _ opacity: String?,
        theme: String,
        script: [[String: Any]] = [],
        _ body: (XCUIApplication) -> Void
    ) {
        let app = BattyUITestHarness.launchBatty(script: script, extraArguments: themeArguments(theme))
        defer { app.terminate() }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(firstPane(in: app).waitForExistence(timeout: 10))

        if let opacity {
            withSettings(in: app) { setTerminalOpacity(opacity, in: app) }
        }
        attachScreenshot(named: "before-gesture")

        continueAfterFailure = true
        body(app)
        continueAfterFailure = false

        if opacity != nil {
            withSettings(in: app) { app.buttons["appearance-background.restore-defaults"].click() }
        }
    }

    @MainActor
    private func firstPane(in app: XCUIApplication) -> XCUIElement {
        panes(in: app).element(boundBy: 0)
    }

    @MainActor
    private func screenPoint(x: CGFloat, y: CGFloat, in app: XCUIApplication) -> XCUICoordinate {
        let window = app.windows.firstMatch
        return window.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: x - window.frame.minX, dy: y - window.frame.minY))
    }

    @MainActor
    private func titleBarPoint(x: CGFloat, fromTop: CGFloat = 14, in app: XCUIApplication) -> XCUICoordinate {
        let y = app.windows.firstMatch.frame.minY + fromTop
        for button in app.toolbars.buttons.allElementsBoundByIndex {
            XCTAssertFalse(
                button.frame.contains(CGPoint(x: x, y: y)),
                "The drag point (\(x), \(y)) is on the toolbar button \(button.identifier)"
            )
        }
        return screenPoint(x: x, y: y, in: app)
    }

    /// Near the session title, in the band a real Mac wouldn't drag from. That
    /// Mac's log didn't record the window's height, so this height is an estimate.
    @MainActor
    private func titleHeightPoint(in app: XCUIApplication) -> XCUICoordinate {
        titleBarPoint(x: firstPane(in: app).frame.minX + 100, fromTop: 26, in: app)
    }

    private func skipUnlessDoubleClickZooms() throws {
        let action = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleActionOnDoubleClick"] as? String
        guard action == nil || action == "Maximize" || action == "Fill" else {
            throw XCTSkip("The system's title bar double-click action is \(action ?? "unset"), not zoom")
        }
    }

    @MainActor
    private func assertDoubleClickZoomsWindow(at point: XCUICoordinate, in app: XCUIApplication) {
        let window = app.windows.firstMatch
        let before = window.frame
        point.doubleClick()
        XCTAssertTrue(
            BattyUITestHarness.waitFor({ window.frame.size != before.size }, timeout: 5, description: "the window to zoom"),
            "Double-clicking the title bar should zoom the window, frame stayed \(before)"
        )
    }

    @MainActor
    private func assertTitleBarOverTheTerminalDragsTheWindow(in app: XCUIApplication) {
        assertDragMovesWindow(from: titleBarPoint(x: firstPane(in: app).frame.midX, in: app), in: app)
    }

    @MainActor
    private func assertDragMovesWindow(from start: XCUICoordinate, in app: XCUIApplication) {
        let window = app.windows.firstMatch
        let before = window.frame
        start.press(
            forDuration: 0.2,
            thenDragTo: start.withOffset(CGVector(dx: Self.dragDistance, dy: Self.dragDistance))
        )
        let moved = BattyUITestHarness.waitFor({
            let frame = window.frame
            return abs(frame.minX - before.minX - Self.dragDistance) <= Self.dragTolerance
                && abs(frame.minY - before.minY - Self.dragDistance) <= Self.dragTolerance
                && frame.size == before.size
        }, timeout: 5, description: "the window to follow the drag")
        if !moved { attachScreenshot(named: "window-did-not-move") }
        XCTAssertTrue(moved, "The window should follow the drag: frame went from \(before) to \(window.frame)")
    }

    @MainActor
    private func collapseSidebar(in app: XCUIApplication) {
        let sidebar = BattyUITestHarness.sidebar(in: app)
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5))
        let expandedWidth = sidebar.frame.width
        app.typeKey("b", modifierFlags: [.command])
        XCTAssertTrue(
            BattyUITestHarness.waitFor({ BattyUITestHarness.isSidebarCollapsed(in: app, expandedWidth: expandedWidth) }, timeout: 5, description: "the Sidebar to collapse"),
            "Cmd-B should collapse the Sidebar"
        )
    }

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
