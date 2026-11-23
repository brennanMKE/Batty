// SidebarRailTests.swift

import XCTest

/// The `compactSidebar` experiment (#0679): Opt-Cmd-B switches the key
/// window's Sidebar between names and the symbols-only rail. The rail is
/// narrower than half the names width, so these tests read explicit width
/// ranges instead of `isSidebarCollapsed`.
nonisolated final class SidebarRailTests: XCTestCase {
    private static let railRange: ClosedRange<CGFloat> = 40...100
    private static let namesRange: ClosedRange<CGFloat> = 170...330

    override func setUpWithError() throws {
        continueAfterFailure = false
        BattyUITestHarness.sweepSentinels()
    }

    override func tearDownWithError() throws {
        BattyUITestHarness.sweepSentinels()
    }

    @MainActor
    private func launch(sessions: [String] = [], extraEnvironment: [String: String] = [:]) -> XCUIApplication {
        let script: [[String: Any]] = sessions.map { ["intent": "createSession", "name": $0] }
        let app = BattyUITestHarness.launchBatty(script: script, extraEnvironment: extraEnvironment)
        XCTAssertNil(BattyUITestHarness.waitForDriverErrors(), "Driver script failed")
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(BattyUITestHarness.sidebar(in: app).waitForExistence(timeout: 5))
        return app
    }

    @MainActor
    private func width(_ app: XCUIApplication) -> CGFloat? {
        BattyUITestHarness.sidebarWidth(in: app)
    }

    @MainActor
    private func waitForWidth(in range: ClosedRange<CGFloat>, _ app: XCUIApplication) -> Bool {
        waitFor({ self.width(app).map(range.contains) == true }, timeout: 5)
    }

    @MainActor
    private func toggleStyle(_ app: XCUIApplication) {
        app.typeKey("b", modifierFlags: [.command, .option])
    }

    @MainActor
    func testOptionCmdBTogglesRailAndBack() throws {
        let app = launch()
        defer { app.terminate() }
        let start = try XCTUnwrap(width(app))
        XCTAssertTrue(Self.namesRange.contains(start), "starts with names: \(start)")

        toggleStyle(app)
        XCTAssertTrue(waitForWidth(in: Self.railRange, app), "Opt-Cmd-B must narrow to the rail: \(width(app) ?? -1)")

        toggleStyle(app)
        XCTAssertTrue(
            waitFor({ self.width(app).map { abs($0 - start) <= 4 } == true }, timeout: 5),
            "Opt-Cmd-B again must restore the names width \(start): \(width(app) ?? -1)"
        )
    }

    @MainActor
    func testCmdBHidesAndShowsInRailStyle() throws {
        let app = launch()
        defer { app.terminate() }
        toggleStyle(app)
        XCTAssertTrue(waitForWidth(in: Self.railRange, app))

        app.typeKey("b", modifierFlags: [.command])
        XCTAssertTrue(waitFor({ (self.width(app) ?? 0) < 20 }, timeout: 5), "Cmd-B must hide the rail")

        app.typeKey("b", modifierFlags: [.command])
        XCTAssertTrue(waitForWidth(in: Self.railRange, app), "Cmd-B must bring the rail back: \(width(app) ?? -1)")
    }

    @MainActor
    func testStyleCommandWhileHiddenKeepsItHiddenAndCmdBShowsNewStyle() throws {
        let app = launch()
        defer { app.terminate() }
        app.typeKey("b", modifierFlags: [.command])
        XCTAssertTrue(waitFor({ (self.width(app) ?? 0) < 20 }, timeout: 5))

        toggleStyle(app)
        XCTAssertFalse(
            waitFor({ (self.width(app) ?? 0) >= 20 }, timeout: 2),
            "Opt-Cmd-B must not show the hidden Sidebar: \(width(app) ?? -1)"
        )

        app.typeKey("b", modifierFlags: [.command])
        XCTAssertTrue(waitForWidth(in: Self.railRange, app), "Cmd-B must show the Sidebar as a rail: \(width(app) ?? -1)")
    }

    @MainActor
    func testCmdNumberSelectsSessionInRail() throws {
        let app = launch(sessions: ["Second"])
        defer { app.terminate() }
        toggleStyle(app)
        XCTAssertTrue(waitForWidth(in: Self.railRange, app))

        let second = BattyUITestHarness.sessionRow(named: "Second", in: app)
        XCTAssertTrue(second.waitForExistence(timeout: 5))
        app.typeKey("2", modifierFlags: [.command])
        XCTAssertTrue(waitFor({ (second.value as? String)?.hasPrefix("selected") == true }, timeout: 5))
        app.typeKey("1", modifierFlags: [.command])
        XCTAssertTrue(waitFor({ (second.value as? String)?.hasPrefix("unselected") == true }, timeout: 5))
    }

    @MainActor
    func testRailRowsAndFooterButtonsRemainReachable() throws {
        let app = launch(sessions: ["Second"])
        defer { app.terminate() }
        toggleStyle(app)
        XCTAssertTrue(waitForWidth(in: Self.railRange, app))

        XCTAssertTrue(BattyUITestHarness.sessionRow(named: "Second", in: app).waitForExistence(timeout: 5))
        let add = app.descendants(matching: .any).matching(identifier: "session-sidebar.add-session-button").firstMatch
        let open = app.descendants(matching: .any).matching(identifier: "session-sidebar.open-project-button").firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        XCTAssertTrue(open.exists)
        XCTAssertTrue(add.isHittable)
        XCTAssertTrue(open.isHittable)

        let outline = BattyUITestHarness.sidebar(in: app)
        let before = outline.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'session-row.'")).count
        add.click()
        XCTAssertTrue(waitFor({
            outline.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'session-row.'")).count == before + 1
        }, timeout: 5), "+ in the rail must add a Session row")
    }

    @MainActor
    func testStyleCommandAbsentWithFlagForcedOff() throws {
        let app = launch(extraEnvironment: ["BATTY_UI_TEST_FORCE_COMPACT_SIDEBAR_OFF": "1"])
        defer { app.terminate() }
        let start = try XCTUnwrap(width(app))

        toggleStyle(app)
        XCTAssertFalse(
            waitFor({ self.width(app).map { abs($0 - start) > 4 } ?? true }, timeout: 2),
            "with the flag off Opt-Cmd-B must not change the Sidebar"
        )

        let menuBar = app.menuBars.firstMatch
        menuBar.menuBarItems["View"].click()
        XCTAssertTrue(menuBar.menuItems["Toggle Sidebar"].waitForExistence(timeout: 5))
        XCTAssertFalse(menuBar.menuItems["Show Symbols Only"].exists)
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
    }
}
