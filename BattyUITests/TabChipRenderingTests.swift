// TabChipRenderingTests.swift

import XCTest

/// Tab chip rendering regression suite for [[0164]].
///
/// Asserts chip uniqueness and basic structure. Frame-based assertions
/// (chip overflow, add-button reachability) use the accessibility frame
/// API and require a running, visible app window.
nonisolated final class TabChipRenderingTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
        BattyUITestHarness.sweepSentinels()
    }

    override func tearDownWithError() throws {
        BattyUITestHarness.sweepSentinels()
    }

    // MARK: - Per-tab title uniqueness — would catch [[0050]]

    /// Three sessions with distinct names produce three distinct session rows.
    /// (The tab chip uniqueness test mirrors this for tabs.)
    @MainActor
    func testThreeSessionsHaveDistinctRowIdentifiers() throws {
        // [[0050]]: chips all showed same user@host — verify per-entity identity.
        let app = BattyUITestHarness.launchBatty(script: [
            ["intent": "renameSession", "from": "Session 1", "to": "Alpha"],
            ["intent": "createSession", "name": "Beta"],
            ["intent": "createSession", "name": "Gamma"]
        ])
        defer { app.terminate() }

        XCTAssertNil(BattyUITestHarness.waitForDriverErrors(), "Driver script failed")
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        let alpha = BattyUITestHarness.sessionRow(named: "Alpha", in: app)
        let beta = BattyUITestHarness.sessionRow(named: "Beta", in: app)
        let gamma = BattyUITestHarness.sessionRow(named: "Gamma", in: app)

        XCTAssertTrue(alpha.waitForExistence(timeout: 5), "Alpha row must exist")
        XCTAssertTrue(beta.waitForExistence(timeout: 5), "Beta row must exist")
        XCTAssertTrue(gamma.waitForExistence(timeout: 5), "Gamma row must exist")
    }

    /// Two tabs renamed to different names produce distinct chip identifiers.
    @MainActor
    func testTwoRenamedTabsHaveDistinctChipIdentifiers() throws {
        // [[0050]] regression: if chip identifiers collide, assertion fails.
        let app = BattyUITestHarness.launchBatty(script: [
            ["intent": "renameActiveTab", "to": "TabAlpha"],
            ["intent": "createTab"],
            ["intent": "renameActiveTab", "to": "TabBeta"]
        ])
        defer { app.terminate() }

        XCTAssertNil(BattyUITestHarness.waitForDriverErrors(), "Driver script failed")
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        let chipAlpha = app.descendants(matching: .any)
            .matching(identifier: "tab-chip.TabAlpha").firstMatch
        let chipBeta = app.descendants(matching: .any)
            .matching(identifier: "tab-chip.TabBeta").firstMatch

        XCTAssertTrue(chipAlpha.waitForExistence(timeout: 5),
                      "tab-chip.TabAlpha must exist ([[0050]] regression)")
        XCTAssertTrue(chipBeta.waitForExistence(timeout: 5),
                      "tab-chip.TabBeta must exist ([[0050]] regression)")
    }

    // MARK: - Tab bar stays inside pane bounds — would catch [[0047]]

    /// Tab bar frame width must not exceed its pane's terminal frame width.
    @MainActor
    func testTabBarWidthDoesNotExceedPaneWidth() throws {
        // [[0047]]: tab bar contents rendered past the pane's trailing edge.
        let app = BattyUITestHarness.launchBatty(script: [
            ["intent": "renameActiveTab", "to": "T1"],
            ["intent": "createTab"],
            ["intent": "renameActiveTab", "to": "T2"],
            ["intent": "createTab"],
            ["intent": "renameActiveTab", "to": "T3"]
        ])
        defer { app.terminate() }

        XCTAssertNil(BattyUITestHarness.waitForDriverErrors(), "Driver script failed")
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        let tabBars = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'tab-bar.'"))
        let panes = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'pane-terminal.'"))

        XCTAssertTrue(waitFor({ tabBars.count >= 1 && panes.count >= 1 }, timeout: 10))

        let tabBarFrame = tabBars.element(boundBy: 0).frame
        let paneFrame = panes.element(boundBy: 0).frame

        XCTAssertLessThanOrEqual(
            tabBarFrame.maxX, paneFrame.maxX + 2,
            "Tab bar trailing edge must not exceed pane trailing edge ([[0047]] regression)"
        )
    }

    // MARK: - Header controls stay inside a narrow terminal pane (#0460)

    @MainActor
    func testNarrowTerminalPaneHeaderControlsStayInsidePane() throws {
        try assertNarrowPaneControlsInside(extraTabs: 0)
    }

    @MainActor
    func testNarrowTerminalPaneHeaderControlsStayInsidePaneWithThreeTabs() throws {
        try assertNarrowPaneControlsInside(extraTabs: 2)
    }

    @MainActor
    private func assertNarrowPaneControlsInside(extraTabs: Int) throws {
        let app = BattyUITestHarness.launchBatty()
        defer { app.terminate() }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        for _ in 0..<extraTabs { app.typeKey("t", modifierFlags: [.command]) }
        app.typeKey("d", modifierFlags: [.command])

        let panes = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'pane-terminal.'"))
        XCTAssertTrue(waitFor({ panes.count >= 2 }, timeout: 10), "Expected two panes after Cmd-D")
        let ordered = panes.allElementsBoundByIndex.sorted { $0.frame.minX < $1.frame.minX }
        let left = ordered[0]
        let right = ordered[1]
        XCTAssertTrue(left.waitForExistence(timeout: 5))

        let window = app.windows.firstMatch
        let origin = window.coordinate(withNormalizedOffset: .zero)
        func point(_ x: CGFloat, _ y: CGFloat) -> XCUICoordinate {
            origin.withOffset(CGVector(dx: x - window.frame.minX, dy: y - window.frame.minY))
        }
        let y = left.frame.midY
        let targetX = left.frame.minX + 300
        for offset in stride(from: CGFloat(-1), through: 11, by: 2) {
            let dividerX = (left.frame.maxX + right.frame.minX) / 2 + offset
            point(dividerX, y).press(forDuration: 0.1, thenDragTo: point(targetX, y))
            if waitFor({ left.frame.width < 340 }, timeout: 2) { break }
        }
        XCTAssertLessThan(left.frame.width, 340, "the Split divider did not move; the pane is not narrow")

        let paneID = String(left.identifier.dropFirst("pane-terminal.".count))
        let handle = BattyScreen.element("pane-drag-handle.\(paneID)", in: app)
        let eye = BattyScreen.element("pane-eye-button.\(paneID)", in: app)
        XCTAssertTrue(handle.waitForExistence(timeout: 5), "drag handle must exist")
        XCTAssertTrue(eye.waitForExistence(timeout: 5), "eye button must exist")
        XCTAssertTrue(handle.isHittable, "drag handle must be hittable")
        XCTAssertTrue(eye.isHittable, "eye button must be hittable")
        XCTAssertLessThanOrEqual(handle.frame.maxX, left.frame.maxX, "drag handle clipped by the pane edge (#0460)")
        XCTAssertLessThanOrEqual(eye.frame.maxX, left.frame.maxX, "eye button clipped by the pane edge (#0460)")

        let plus = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == 'New tab'"))
            .allElementsBoundByIndex
            .first { $0.frame.minX >= left.frame.minX && $0.frame.midX <= left.frame.maxX }
        let plusButton = try XCTUnwrap(plus, "the left pane's New tab button must exist")
        XCTAssertLessThanOrEqual(plusButton.frame.maxX, left.frame.maxX, "New tab button clipped by the pane edge (#0460)")
    }

    // MARK: - Home dir tab shows "~" by default — [[0142]] default case

    /// A fresh tab (likely at $HOME) shows a non-empty chip title.
    @MainActor
    func testDefaultTabHasNonEmptyChipTitle() throws {
        // [[0142]]: verify the home-dir "~" default renders as a valid chip identifier.
        let app = BattyUITestHarness.launchBatty()
        defer { app.terminate() }

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        let chips = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'tab-chip.'"))
        XCTAssertTrue(waitFor({ chips.count >= 1 }, timeout: 5),
                      "At least one tab chip must be visible on cold launch")

        for i in 0..<chips.count {
            let id = chips.element(boundBy: i).identifier
            XCTAssertTrue(id.count > "tab-chip.".count,
                          "Chip identifier must not be empty (tab-chip. only)")
        }
    }
}

extension TabChipRenderingTests {}
