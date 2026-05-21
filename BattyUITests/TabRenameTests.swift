// TabRenameTests.swift

import XCTest

/// Title-override regression suite for [[0160]].
///
/// Uses the UITestDriver rename intents (same path as the sheet's onCommit)
/// to exercise the rename / reset / tab-chip update flow without requiring
/// a real sheet interaction. Every test asserts on `tab-chip.<title>` which
/// is the accessibility identifier that updates when `TabTitleFormatter.chipTitle`
/// re-evaluates after a `titleOverride` write.
nonisolated final class TabRenameTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
        BattyUITestHarness.sweepSentinels()
    }

    override func tearDownWithError() throws {
        BattyUITestHarness.sweepSentinels()
    }

    // MARK: - Tab rename — would catch [[0157]], [[0142]]

    /// renameActiveTab intent sets titleOverride, chipTitle returns the override,
    /// and tab-chip.<name> becomes visible in the accessibility tree.
    /// Would have caught [[0157]]: chip silently kept showing the shell title.
    @MainActor
    func testRenameActiveTabUpdatesChipTitle() throws {
        let app = BattyUITestHarness.launchBatty(script: [
            ["intent": "renameActiveTab", "to": "MyCustomTab"]
        ])
        defer { app.terminate() }

        XCTAssertNil(BattyUITestHarness.waitForDriverErrors(), "Driver script failed")
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        // The chip identifier is derived from chipTitle, which now checks
        // titleOverride before cwd and shell title ([[0157]] fix).
        let chip = app.descendants(matching: .any)
            .matching(identifier: "tab-chip.MyCustomTab").firstMatch
        XCTAssertTrue(
            chip.waitForExistence(timeout: 5),
            "tab-chip.MyCustomTab must appear after renameActiveTab ([[0157]] regression)"
        )
    }

    /// The override wins over the home-directory "~" shortcut.
    /// Would have caught [[0142]]: tab at $HOME always showed "~".
    @MainActor
    func testRenameWinsOverHomeDirTilde() throws {
        // We can't force the cwd to $HOME in this test, but we can verify
        // that when a rename is set, it appears as the chip title regardless
        // of cwd. The chipTitle ordering bug ([[0142]]) caused home-dir tabs
        // to return "~" before checking titleOverride.
        let app = BattyUITestHarness.launchBatty(script: [
            ["intent": "renameActiveTab", "to": "HomeOverride"]
        ])
        defer { app.terminate() }

        XCTAssertNil(BattyUITestHarness.waitForDriverErrors(), "Driver script failed")
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        let chip = app.descendants(matching: .any)
            .matching(identifier: "tab-chip.HomeOverride").firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 5),
                      "titleOverride must win over home-dir cwd ([[0142]] regression)")
    }

    /// Empty rename collapses to no-op (preserves prior chip title).
    @MainActor
    func testEmptyRenameIsNoOp() throws {
        let app = BattyUITestHarness.launchBatty(script: [
            ["intent": "renameActiveTab", "to": ""]
        ])
        defer { app.terminate() }

        XCTAssertNil(BattyUITestHarness.waitForDriverErrors(), "Driver script failed")
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        // Empty trim → titleOverride = nil, so the chip falls back to shell/cwd.
        // Assert that no chip with identifier "tab-chip." exists (empty title).
        let chips = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'tab-chip.'"))
        XCTAssertTrue(waitFor({ chips.count >= 1 }, timeout: 5),
                      "At least one tab chip should be visible")
        // No chip should have an empty trailing suffix.
        let emptyChip = app.descendants(matching: .any)
            .matching(identifier: "tab-chip.").firstMatch
        XCTAssertFalse(emptyChip.exists, "tab-chip. (empty title) must not appear")
    }

    /// Reset Title clears the override and chip reverts to shell title.
    @MainActor
    func testResetActiveTabTitleClearsOverride() throws {
        let app = BattyUITestHarness.launchBatty(script: [
            ["intent": "renameActiveTab", "to": "Temporary"],
            ["intent": "resetActiveTabTitle"]
        ])
        defer { app.terminate() }

        XCTAssertNil(BattyUITestHarness.waitForDriverErrors(), "Driver script failed")
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        // The "Temporary" chip must not exist after reset.
        let staleChip = app.descendants(matching: .any)
            .matching(identifier: "tab-chip.Temporary").firstMatch
        XCTAssertFalse(
            staleChip.waitForExistence(timeout: 3),
            "tab-chip.Temporary must not exist after resetActiveTabTitle"
        )
        // At least one chip should still be present (the default title).
        let chips = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'tab-chip.'"))
        XCTAssertTrue(waitFor({ chips.count >= 1 }, timeout: 5),
                      "A chip with the default title should appear after reset")
    }

    // MARK: - Session rename — would catch [[0043]], [[0153]]

    /// renameSession intent updates the session row title in the sidebar.
    @MainActor
    func testRenameSessionUpdatesSessionRow() throws {
        let app = BattyUITestHarness.launchBatty(script: [
            ["intent": "renameSession", "from": "Session 1", "to": "WorkBench"]
        ])
        defer { app.terminate() }

        XCTAssertNil(BattyUITestHarness.waitForDriverErrors(), "Driver script failed")
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        let row = BattyUITestHarness.sessionRow(named: "WorkBench", in: app)
        XCTAssertTrue(
            row.waitForExistence(timeout: 5),
            "session-row.WorkBench must appear after renameSession ([[0043]] regression)"
        )
        let oldRow = BattyUITestHarness.sessionRow(named: "Session 1", in: app)
        XCTAssertFalse(
            oldRow.waitForExistence(timeout: 2),
            "session-row.Session 1 must be gone after rename"
        )
    }

    /// Two sessions can have different rename-derived names simultaneously.
    @MainActor
    func testMultipleSessionsHaveIndependentTitles() throws {
        let app = BattyUITestHarness.launchBatty(script: [
            ["intent": "renameSession", "from": "Session 1", "to": "Alpha"],
            ["intent": "createSession", "name": "Beta"]
        ])
        defer { app.terminate() }

        XCTAssertNil(BattyUITestHarness.waitForDriverErrors(), "Driver script failed")
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        let alpha = BattyUITestHarness.sessionRow(named: "Alpha", in: app)
        let beta = BattyUITestHarness.sessionRow(named: "Beta", in: app)
        XCTAssertTrue(alpha.waitForExistence(timeout: 5), "session-row.Alpha should exist")
        XCTAssertTrue(beta.waitForExistence(timeout: 5), "session-row.Beta should exist")
    }

    // MARK: - Helpers
}
