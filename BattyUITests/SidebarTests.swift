// SidebarTests.swift

import XCTest

/// Sidebar toggle regression suite for [[0167]].
///
/// Asserts `Cmd-B` collapses/expands the sidebar, that the sidebar element
/// is visible by default, and that session-row selection doesn't collapse it.
nonisolated final class SidebarTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
        BattyUITestHarness.sweepSentinels()
    }

    override func tearDownWithError() throws {
        BattyUITestHarness.sweepSentinels()
    }

    // MARK: - Sidebar visibility

    /// Sidebar is expanded by default on cold launch.
    @MainActor
    func testSidebarVisibleOnColdLaunch() throws {
        let app = BattyUITestHarness.launchBatty()
        defer { app.terminate() }

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        let sidebar = BattyUITestHarness.sidebar(in: app)
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5), "Sidebar must be visible on launch")
        XCTAssertGreaterThan(sidebar.frame.width, 50,
                             "Sidebar must have positive width when expanded")
    }

    /// Cmd-B collapses the sidebar. [[0129]] regression — the shortcut must be wired.
    @MainActor
    func testCmdBCollapsesAndExpandsSidebar() throws {
        let app = BattyUITestHarness.launchBatty()
        defer { app.terminate() }

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        let sidebar = BattyUITestHarness.sidebar(in: app)
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5))
        let expandedWidth = sidebar.frame.width

        // Collapse.
        app.typeKey("b", modifierFlags: [.command])
        XCTAssertTrue(
            waitFor({ !sidebar.isHittable || sidebar.frame.width < expandedWidth / 2 }, timeout: 5),
            "Cmd-B must collapse the sidebar ([[0129]] regression)"
        )

        // Re-expand.
        app.typeKey("b", modifierFlags: [.command])
        XCTAssertTrue(
            waitFor({ sidebar.isHittable && sidebar.frame.width > expandedWidth / 2 }, timeout: 5),
            "Second Cmd-B must re-expand the sidebar"
        )
    }

    /// Selecting a session row does not collapse the sidebar. [[0065]] regression.
    @MainActor
    func testSelectingSessionRowKeepsSidebarExpanded() throws {
        let app = BattyUITestHarness.launchBatty(script: [
            ["intent": "createSession", "name": "Secondary"]
        ])
        defer { app.terminate() }

        XCTAssertNil(BattyUITestHarness.waitForDriverErrors(), "Driver script failed")
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        let sidebar = BattyUITestHarness.sidebar(in: app)
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5))
        let initialWidth = sidebar.frame.width

        let secondaryRow = BattyUITestHarness.sessionRow(named: "Secondary", in: app)
        XCTAssertTrue(secondaryRow.waitForExistence(timeout: 5))
        secondaryRow.click()

        XCTAssertTrue(
            waitFor({ sidebar.frame.width >= initialWidth - 10 }, timeout: 3),
            "Selecting a session row must not collapse the sidebar ([[0065]] regression)"
        )
    }

    // MARK: - Helpers

    private func waitFor(_ predicate: @escaping () -> Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return predicate()
    }
}
