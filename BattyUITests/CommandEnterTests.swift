// CommandEnterTests.swift

import XCTest

/// Covers `#0468` — Cmd-Return at a plain shell prompt must run the command
/// instead of inserting the tail of `ESC[27;9;13~` into the line editor.
nonisolated final class CommandEnterTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
        BattyUITestHarness.sweepSentinels()
    }

    override func tearDownWithError() throws {
        BattyUITestHarness.sweepSentinels()
    }

    @MainActor
    func testCommandReturnRunsCommandAtShellPrompt() throws {
        let app = BattyUITestHarness.launchBatty()
        defer { app.terminate() }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        let pane = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'pane-terminal.'"))
            .firstMatch
        XCTAssertTrue(pane.waitForExistence(timeout: 5))
        pane.click()

        let sentinel = BattyUITestHarness.sentinelPath(named: "command-enter")
        app.typeText("touch '\(sentinel)'")
        app.typeKey(.return, modifierFlags: .command)

        XCTAssertTrue(BattyUITestHarness.waitForFile(at: sentinel, timeout: 10),
                      "Cmd-Return at the zsh prompt should have run the command")
    }
}
