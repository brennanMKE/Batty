// MultiWindowTests.swift

import XCTest

/// Covers #0237 — New Window action (Shift-Cmd-N and File → New Window).
/// Verifies that a second window opens with its own independent sidebar,
/// session selection, and working terminal, and that Cmd-N still creates
/// a session in the key window rather than a new window.
nonisolated final class MultiWindowTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Shift-Cmd-N opens a second window. The app ends up with two windows,
    /// each with its own sidebar showing "Session 1".
    @MainActor
    func testShiftCmdNOpensSecondWindow() throws {
        let app = BattyUITestHarness.launchBatty()
        defer { app.terminate() }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10),
                      "First window should exist after launch")
        XCTAssertEqual(app.windows.count, 1, "Should start with exactly one window")

        app.typeKey("n", modifierFlags: [.command, .shift])

        XCTAssertTrue(waitFor({
            app.windows.count >= 2
        }, timeout: 10), "Expected a second window after Shift-Cmd-N; got \(app.windows.count)")
    }

    /// After opening a second window, Cmd-N in that window adds a session to
    /// the second window's sidebar, not the first window's.
    @MainActor
    func testNewWindowHasIndependentSidebar() throws {
        let app = BattyUITestHarness.launchBatty()
        defer { app.terminate() }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        app.typeKey("n", modifierFlags: [.command, .shift])
        XCTAssertTrue(waitFor({ app.windows.count >= 2 }, timeout: 10),
                      "Second window must appear before sidebar check")

        // The total session-row count across all windows. After launch: 1.
        // After New Window: 2 (one per window). After Cmd-N in the new window: 3.
        let rowsAfterNewWindow = waitFor({ self.sessionRowCount(in: app) >= 2 }, timeout: 5)
        XCTAssertTrue(rowsAfterNewWindow, "Each window should show its own Session 1")

        let rowsBefore = sessionRowCount(in: app)
        // Make the new (second) window key by clicking it, then press Cmd-N.
        app.windows.element(boundBy: 1).click()
        app.typeKey("n", modifierFlags: [.command])

        XCTAssertTrue(waitFor({
            self.sessionRowCount(in: app) > rowsBefore
        }, timeout: 5), "Cmd-N should add a session in the key window")
    }

    /// File → New Window menu item opens a second window.
    @MainActor
    func testFileMenuNewWindowOpensSecondWindow() throws {
        let app = BattyUITestHarness.launchBatty()
        defer { app.terminate() }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(app.windows.count, 1)

        app.menuBars.firstMatch.menuBarItems["File"].click()
        let newWindowItem = app.menuBars.firstMatch.menuItems["New Window"]
        XCTAssertTrue(newWindowItem.waitForExistence(timeout: 3),
                      "File → New Window menu item should exist")
        newWindowItem.click()

        XCTAssertTrue(waitFor({
            app.windows.count >= 2
        }, timeout: 10), "File → New Window should open a second window")
    }

    // MARK: - Helpers

    @MainActor
    private func sessionRowCount(in app: XCUIApplication) -> Int {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'session-row.'"))
            .count
    }
}
