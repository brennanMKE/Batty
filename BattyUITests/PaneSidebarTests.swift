// PaneSidebarTests.swift

import XCTest

/// Sidebar pane-tree suite for [[0258]] (regressions from [[0256]]).
///
/// Covers: the session-row chevron expanding/collapsing the pane list,
/// clicking a pane row never blanking the detail area (the pane-id →
/// selectedSessionID leak), hide auto-expanding the pane list, and the
/// last-visible-pane eye staying disabled.
nonisolated final class PaneSidebarTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
        BattyUITestHarness.sweepSentinels()
    }

    override func tearDownWithError() throws {
        BattyUITestHarness.sweepSentinels()
    }

    // MARK: - Element lookups

    /// The session row's native outline disclosure triangle (DisclosureGroup
    /// in the sidebar List maps onto NSOutlineView expansion).
    @MainActor
    private func chevron(in app: XCUIApplication) -> XCUIElement {
        let triangle = app.disclosureTriangles.firstMatch
        if triangle.exists { return triangle }
        return app.descendants(matching: .disclosureTriangle).firstMatch
    }

    @MainActor
    private func paneRowCount(in app: XCUIApplication) -> Int {
        app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'pane-row.'")
        ).count
    }

    @MainActor
    private func firstPaneRow(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'pane-row.'")
        ).firstMatch
    }

    @MainActor
    private func firstEyeToggle(in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'pane-eye-toggle.'")
        ).firstMatch
    }

    @MainActor
    private func noSessionPlaceholder(in app: XCUIApplication) -> XCUIElement {
        app.staticTexts["No Session Selected"].firstMatch
    }

    // MARK: - Chevron expand/collapse

    /// The pane list starts collapsed (even after a split), the chevron
    /// expands it, and a second click collapses it again — for any pane count.
    @MainActor
    func testChevronExpandsAndCollapsesPaneList() throws {
        let app = BattyUITestHarness.launchBatty()
        defer { app.terminate() }

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        app.typeKey("d", modifierFlags: [.command])

        // Collapsed by default: no pane rows even with 2 panes.
        pause(0.5)
        XCTAssertEqual(paneRowCount(in: app), 0,
                       "Pane list must start collapsed")

        let disclosure = chevron(in: app)
        XCTAssertTrue(disclosure.waitForExistence(timeout: 5),
                      "Session row must show a disclosure chevron")

        disclosure.click()
        XCTAssertTrue(
            waitFor({ self.paneRowCount(in: app) == 2 }, timeout: 5),
            "Expanding must reveal one row per pane"
        )

        disclosure.click()
        XCTAssertTrue(
            waitFor({ self.paneRowCount(in: app) == 0 }, timeout: 5),
            "Second click must collapse the pane list"
        )
    }

    /// Single-pane sessions expose the chevron too.
    @MainActor
    func testChevronPresentForSinglePaneSession() throws {
        let app = BattyUITestHarness.launchBatty()
        defer { app.terminate() }

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        let disclosure = chevron(in: app)
        XCTAssertTrue(disclosure.waitForExistence(timeout: 5),
                      "Chevron must exist for a single-pane session")

        disclosure.click()
        XCTAssertTrue(
            waitFor({ self.paneRowCount(in: app) == 1 }, timeout: 5),
            "Expanding a single-pane session must show its one pane row"
        )
    }

    // MARK: - Selection leak ([[0258]] core regression)

    /// Clicking a pane row must not write the pane id into the session
    /// selection — the detail area must never show "No Session Selected".
    @MainActor
    func testClickingPaneRowDoesNotBlankSession() throws {
        let app = BattyUITestHarness.launchBatty()
        defer { app.terminate() }

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        app.typeKey("d", modifierFlags: [.command])

        let disclosure = chevron(in: app)
        XCTAssertTrue(disclosure.waitForExistence(timeout: 5))
        disclosure.click()
        XCTAssertTrue(waitFor({ self.paneRowCount(in: app) == 2 }, timeout: 5))

        firstPaneRow(in: app).click()
        pause(1)
        XCTAssertFalse(noSessionPlaceholder(in: app).exists,
                       "Clicking a pane row must not deselect the session ([[0258]] regression)")
        XCTAssertEqual(paneRowCount(in: app), 2,
                       "Pane rows must survive a pane-row click")
    }

    // MARK: - Hide / show via the sidebar

    /// Hiding a pane from its title-row eye auto-expands the sidebar pane
    /// list, and the hidden pane's row (the restore control) is present.
    @MainActor
    func testHidingPaneAutoExpandsPaneList() throws {
        let app = BattyUITestHarness.launchBatty()
        defer { app.terminate() }

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        app.typeKey("d", modifierFlags: [.command])

        pause(0.5)
        XCTAssertEqual(paneRowCount(in: app), 0, "Pane list starts collapsed")

        let titleEye = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'pane-eye-button.'")
        ).firstMatch
        XCTAssertTrue(titleEye.waitForExistence(timeout: 5),
                      "Pane title rows must show the hide eye after a split")
        titleEye.click()

        XCTAssertTrue(
            waitFor({ self.paneRowCount(in: app) == 2 }, timeout: 5),
            "Hiding a pane must auto-expand the sidebar pane list"
        )
        XCTAssertFalse(noSessionPlaceholder(in: app).exists,
                       "Hiding a pane must not deselect the session")
    }

    /// With a single visible pane, its sidebar eye toggle is disabled —
    /// a session always keeps ≥1 visible terminal.
    @MainActor
    func testEyeDisabledForLastVisiblePane() throws {
        let app = BattyUITestHarness.launchBatty()
        defer { app.terminate() }

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        let disclosure = chevron(in: app)
        XCTAssertTrue(disclosure.waitForExistence(timeout: 5))
        disclosure.click()
        XCTAssertTrue(waitFor({ self.paneRowCount(in: app) == 1 }, timeout: 5))

        let eye = firstEyeToggle(in: app)
        XCTAssertTrue(eye.waitForExistence(timeout: 5))
        XCTAssertFalse(eye.isEnabled,
                       "The last visible pane's eye must be disabled (≥1 visible invariant)")
    }
}
