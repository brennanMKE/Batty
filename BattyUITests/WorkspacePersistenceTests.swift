// WorkspacePersistenceTests.swift

import XCTest

/// Workspace persistence regression suite for [[0165]].
///
/// Tests the round-trip: set up state → terminate → relaunch → assert same state.
/// Each test launches twice: once to set up state (first launch) and once to verify
/// persistence (second launch). This exercises the save-on-structural-change and
/// load-on-launch paths.
nonisolated final class WorkspacePersistenceTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
        BattyUITestHarness.sweepSentinels()
    }

    override func tearDownWithError() throws {
        BattyUITestHarness.sweepSentinels()
    }

    // MARK: - Session persistence — would catch [[0029]] / [[0030]]

    /// Sessions created in one launch appear in the next. Would catch save-trigger regressions.
    @MainActor
    func testSessionsPersistAcrossRelaunch() throws {
        // Launch 1: create two extra sessions.
        let app1 = BattyUITestHarness.launchBatty(script: [
            ["intent": "renameSession", "from": "Session 1", "to": "Alpha"],
            ["intent": "createSession", "name": "Beta"]
        ])

        XCTAssertNil(BattyUITestHarness.waitForDriverErrors(), "Driver script failed")
        XCTAssertTrue(app1.windows.firstMatch.waitForExistence(timeout: 10))

        let alpha1 = BattyUITestHarness.sessionRow(named: "Alpha", in: app1)
        let beta1 = BattyUITestHarness.sessionRow(named: "Beta", in: app1)
        XCTAssertTrue(alpha1.waitForExistence(timeout: 5), "Alpha must appear in launch 1")
        XCTAssertTrue(beta1.waitForExistence(timeout: 5), "Beta must appear in launch 1")

        // Allow workspace save to settle (structural-change save is async).
        BattyUITestHarness.pause(1.5)
        app1.terminate()

        // Launch 2: no script — workspace should restore.
        let app2 = BattyUITestHarness.launchBatty()
        defer { app2.terminate() }

        XCTAssertTrue(app2.windows.firstMatch.waitForExistence(timeout: 10))

        let alpha2 = BattyUITestHarness.sessionRow(named: "Alpha", in: app2)
        let beta2 = BattyUITestHarness.sessionRow(named: "Beta", in: app2)
        XCTAssertTrue(
            alpha2.waitForExistence(timeout: 5),
            "Alpha must persist across relaunch ([[0030]] regression)"
        )
        XCTAssertTrue(
            beta2.waitForExistence(timeout: 5),
            "Beta must persist across relaunch ([[0030]] regression)"
        )
    }

    /// Layout (pane count) persists across relaunch.
    @MainActor
    func testLayoutPersistsAcrossRelaunch() throws {
        // Launch 1: apply a layout.
        let app1 = BattyUITestHarness.launchBatty(script: [
            ["intent": "applyLayout", "layout": "twoByTwoGrid"]
        ])

        XCTAssertNil(BattyUITestHarness.waitForDriverErrors(), "Driver script failed")
        XCTAssertTrue(app1.windows.firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(
            waitFor({ self.panesQuery(in: app1).count == 4 }, timeout: 10),
            "Launch 1 must show 4 panes"
        )

        BattyUITestHarness.pause(1.5)
        app1.terminate()

        // Launch 2: assert 4 panes restored.
        let app2 = BattyUITestHarness.launchBatty()
        defer { app2.terminate() }

        XCTAssertTrue(app2.windows.firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(
            waitFor({ self.panesQuery(in: app2).count == 4 }, timeout: 10),
            "twoByTwoGrid layout must persist across relaunch ([[0029]] regression)"
        )
    }

    /// Tab title overrides persist across relaunch.
    @MainActor
    func testTabTitleOverridePersistsAcrossRelaunch() throws {
        // Launch 1: rename a tab.
        let app1 = BattyUITestHarness.launchBatty(script: [
            ["intent": "renameActiveTab", "to": "PersistentTab"]
        ])

        XCTAssertNil(BattyUITestHarness.waitForDriverErrors(), "Driver script failed")
        XCTAssertTrue(app1.windows.firstMatch.waitForExistence(timeout: 10))

        let chip1 = app1.descendants(matching: .any)
            .matching(identifier: "tab-chip.PersistentTab").firstMatch
        XCTAssertTrue(chip1.waitForExistence(timeout: 5), "Renamed chip must appear in launch 1")

        BattyUITestHarness.pause(1.5)
        app1.terminate()

        // Launch 2: assert chip still has the override.
        let app2 = BattyUITestHarness.launchBatty()
        defer { app2.terminate() }

        XCTAssertTrue(app2.windows.firstMatch.waitForExistence(timeout: 10))
        let chip2 = app2.descendants(matching: .any)
            .matching(identifier: "tab-chip.PersistentTab").firstMatch
        XCTAssertTrue(
            chip2.waitForExistence(timeout: 5),
            "Tab title override must persist across relaunch"
        )
    }

    // MARK: - Helpers

    @MainActor
    private func panesQuery(in app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'pane-terminal.'"))
    }
}
