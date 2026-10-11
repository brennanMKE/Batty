// StuckMouseModeClickTests.swift

import XCTest

/// A click at an idle shell prompt must not type SGR mouse-report bytes into
/// the line editor, even when a program that died earlier left DEC mouse
/// tracking on (#0411).
nonisolated final class StuckMouseModeClickTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testClickAtIdlePromptWithLeakedMouseModeTypesNothing() throws {
        let app = BattyUITestHarness.launchBatty()
        defer { app.terminate() }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        let pane = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'pane-terminal.'"))
            .firstMatch
        XCTAssertTrue(pane.waitForExistence(timeout: 5))
        pane.click()

        let ready = BattyUITestHarness.sentinelPath(named: "stuck-mouse-ready")
        let ran = BattyUITestHarness.sentinelPath(named: "stuck-mouse-ran")
        app.typeText("printf '\\e[?1000h\\e[?1006h'; touch \(ready)\n")
        XCTAssertTrue(BattyUITestHarness.waitForFile(at: ready, timeout: 15),
                      "the shell never enabled mouse tracking")

        pane.click()

        app.typeText("touch \(ran)\n")
        XCTAssertTrue(BattyUITestHarness.waitForFile(at: ran, timeout: 15),
                      "a click at the idle prompt typed mouse-report bytes in front of the next command")
    }

    /// Pins Ghostty's `mouse-shift-capture` default (a Shift-click is not reported to the PTY); passes with the guard off, so it is not guard coverage.
    @MainActor
    func testShiftClickAtStuckPromptTypesNothing() throws {
        let app = BattyUITestHarness.launchBatty()
        defer { app.terminate() }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        let pane = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'pane-terminal.'"))
            .firstMatch
        XCTAssertTrue(pane.waitForExistence(timeout: 5))
        pane.click()

        let ready = BattyUITestHarness.sentinelPath(named: "stuck-mouse-shift-ready")
        let ran = BattyUITestHarness.sentinelPath(named: "stuck-mouse-shift-ran")
        app.typeText("printf '\\e[?1000h\\e[?1006h'; touch \(ready)\n")
        XCTAssertTrue(BattyUITestHarness.waitForFile(at: ready, timeout: 15))

        XCUIElement.perform(withKeyModifiers: .shift) { pane.click() }

        app.typeText("touch \(ran)\n")
        XCTAssertTrue(BattyUITestHarness.waitForFile(at: ran, timeout: 15),
                      "a Shift-click at the stuck prompt typed mouse-report bytes in front of the next command")
    }
}
