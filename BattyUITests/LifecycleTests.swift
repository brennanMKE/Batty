// LifecycleTests.swift

import XCTest

/// Covers `#0094` — session/tab/pane creation and close cascades.
nonisolated final class LifecycleTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testCmdOptionNCreatesSession() throws {
        let app = BattyUITestHarness.launchBatty()
        defer { app.terminate() }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        let rowsBefore = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'session-row.'")).count
        app.typeKey("n", modifierFlags: [.command, .option])

        XCTAssertTrue(waitFor({
            app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH 'session-row.'")).count
                > rowsBefore
        }, timeout: 5), "Expected a new session row after Cmd-Option-N")
    }

    @MainActor
    func testCmdTCreatesTabAndCmdWClosesIt() throws {
        let app = BattyUITestHarness.launchBatty()
        defer { app.terminate() }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        let chipsBefore = chipCount(in: app)
        app.typeKey("t", modifierFlags: [.command])
        XCTAssertTrue(waitFor({ self.chipCount(in: app) == chipsBefore + 1 }, timeout: 5))

        app.typeKey("w", modifierFlags: [.command])
        XCTAssertTrue(waitFor({ self.chipCount(in: app) == chipsBefore }, timeout: 5),
                      "Expected Cmd-W to close the just-opened tab")
    }

    @MainActor
    func testSplitThenCmdWCollapsesPane() throws {
        let app = BattyUITestHarness.launchBatty()
        defer { app.terminate() }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        app.typeKey("d", modifierFlags: [.command])
        XCTAssertTrue(waitFor({ self.tabBarCount(in: app) >= 2 }, timeout: 5))

        app.typeKey("w", modifierFlags: [.command])
        // The cascade should collapse the new pane (last tab → pane removal).
        XCTAssertTrue(waitFor({ self.tabBarCount(in: app) == 1 }, timeout: 5),
                      "Expected pane to collapse after closing its last tab")
    }

    private func chipCount(in app: XCUIApplication) -> Int {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'tab-chip.'"))
            .count
    }

    private func tabBarCount(in app: XCUIApplication) -> Int {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'tab-bar.'"))
            .count
    }
}
