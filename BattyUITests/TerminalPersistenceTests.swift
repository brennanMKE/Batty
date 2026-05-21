// TerminalPersistenceTests.swift

import XCTest

/// Covers `#0095` — terminal persistence across SwiftUI rebuilds. Uses
/// the sentinel-file pattern documented in `BattyUITests/README.md`
/// because XCUITest can't read terminal pixels.
nonisolated final class TerminalPersistenceTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
        BattyUITestHarness.sweepSentinels()
    }

    override func tearDownWithError() throws {
        BattyUITestHarness.sweepSentinels()
    }

    @MainActor
    func testSwitchingSessionsKeepsBackgroundTabAlive() throws {
        let app = BattyUITestHarness.launchBatty()
        defer { app.terminate() }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        // The proof-of-life pattern: type a heartbeat command into the
        // focused terminal, switch sessions, switch back, and verify the
        // sentinel file has been written by the still-running process.
        let sentinel = BattyUITestHarness.sentinelPath(named: "heartbeat")
        let command = "(while true; do touch \(shellEscape(sentinel)); sleep 0.2; done) &"
        // Focus the first pane so typing lands there.
        let pane = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'pane-terminal.'"))
            .firstMatch
        XCTAssertTrue(pane.waitForExistence(timeout: 5))
        pane.click()
        app.typeText(command + "\n")

        // Wait for the first heartbeat tick.
        XCTAssertTrue(BattyUITestHarness.waitForFile(at: sentinel, timeout: 5),
                      "Heartbeat sentinel didn't appear; shell may not have run the command")

        // Create a second session, then jump back. The original session's
        // background shell must still be ticking the sentinel.
        app.typeKey("n", modifierFlags: [.command, .option])
        BattyUITestHarness.pause(0.5)
        // Touch the first session's row to switch back.
        let firstSessionRow = BattyUITestHarness.sessionRow(named: "Session 1", in: app)
        if firstSessionRow.exists {
            firstSessionRow.click()
        }

        // Remove the sentinel and wait — if the process survived, the
        // sentinel reappears within a tick.
        try? FileManager.default.removeItem(atPath: sentinel)
        XCTAssertTrue(BattyUITestHarness.waitForFile(at: sentinel, timeout: 5),
                      "Background process should still be touching the sentinel after a session switch")

        // Kill the heartbeat process before we leave the test so it doesn't
        // outlive the suite. Best-effort.
        app.typeText("kill %1 2>/dev/null\n")
    }

    private func shellEscape(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
