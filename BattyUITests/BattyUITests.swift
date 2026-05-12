// BattyUITests.swift

import XCTest

nonisolated final class BattyUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
        BattyUITestHarness.sweepSentinels()
    }

    override func tearDownWithError() throws {
        BattyUITestHarness.sweepSentinels()
    }

    @MainActor
    func testColdLaunchShowsDefaultSession() throws {
        let app = BattyUITestHarness.launchBatty()
        defer { app.terminate() }

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10), "Main window did not appear within 10s")

        let row = BattyUITestHarness.sessionRow(named: "Session 1", in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 5), "Default 'Session 1' row not found in sidebar")
    }
}
