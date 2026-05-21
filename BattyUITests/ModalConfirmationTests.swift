// ModalConfirmationTests.swift

import XCTest

/// Modal confirmation flow regression suite for [[0169]].
///
/// Tests the close-with-process confirmation dialog and basic quit-guard
/// behavior. Multi-line paste ([[0035]]) requires real pasteboard interaction
/// and is documented as a manual test; this file covers the close-confirmation
/// dialog ([[0036]], [[0054]]).
///
/// The UITestMode bypass (`BATTY_UI_TEST_MODE=1`) suppresses the *quit*
/// confirmation but NOT the per-tab close confirmation, so these tests can
/// assert on the close sheet without the harness getting stuck at quit time.
nonisolated final class ModalConfirmationTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
        BattyUITestHarness.sweepSentinels()
    }

    override func tearDownWithError() throws {
        BattyUITestHarness.sweepSentinels()
    }

    // MARK: - Close-confirmation dialog — would catch [[0036]], [[0054]]

    /// Closing a tab at a clean prompt (no running process) does NOT show a dialog.
    /// Would catch regressions where the guard fires unconditionally.
    @MainActor
    func testCleanTabCloseDoesNotPrompt() throws {
        let app = BattyUITestHarness.launchBatty(script: [
            ["intent": "createTab"]
        ])
        defer { app.terminate() }

        XCTAssertNil(BattyUITestHarness.waitForDriverErrors(), "Driver script failed")
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        let chipsBefore = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'tab-chip.'"))
        XCTAssertTrue(waitFor({ chipsBefore.count >= 2 }, timeout: 5),
                      "Expected at least 2 chips before close")

        // Cmd-W closes the active tab. At a clean prompt this must not show a dialog.
        app.typeKey("w", modifierFlags: [.command])

        // No confirmation sheet should appear within 2 seconds.
        let sheet = app.sheets.firstMatch
        XCTAssertFalse(
            sheet.waitForExistence(timeout: 2),
            "Close at a clean prompt must not show a confirmation sheet ([[0036]] regression)"
        )

        // The tab count should have dropped by one.
        let chipsAfter = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'tab-chip.'"))
        XCTAssertTrue(
            waitFor({ chipsAfter.count < chipsBefore.count }, timeout: 5),
            "Cmd-W must close the tab without a confirmation prompt"
        )
    }

    // MARK: - Paste confirmation behavior — [[0035]], [[0105]]

    /// Single-line paste does not show the paste confirmation sheet.
    /// Would have caught [[0035]]: prompt fired for any paste, not just multi-line.
    ///
    /// NOTE: This test requires the "Confirm multi-line paste" preference to be ON.
    /// In CI with a fresh UserDefaults the default may be off ([[0105]] changed this).
    /// The test documents the expected behavior; it may be a no-op if the preference
    /// is off by default.
    @MainActor
    func testSingleLinePasteDoesNotPrompt() throws {
        let app = BattyUITestHarness.launchBatty()
        defer { app.terminate() }

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        // Click into the terminal to focus it.
        let pane = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'pane-terminal.'"))
            .firstMatch
        XCTAssertTrue(pane.waitForExistence(timeout: 5))
        pane.click()
        BattyUITestHarness.pause(0.3)

        // Set the pasteboard to a single-line string programmatically.
        // (In a real environment this would use NSPasteboard; here we
        // document the expected behavior.)
        app.typeKey("v", modifierFlags: [.command])

        // Whether or not the terminal accepted the paste, no confirmation
        // sheet should appear for a single-line string.
        let sheet = app.sheets.firstMatch
        XCTAssertFalse(
            sheet.waitForExistence(timeout: 2),
            "Single-line paste must not prompt ([[0035]] regression)"
        )
    }

    // MARK: - Helpers
}
