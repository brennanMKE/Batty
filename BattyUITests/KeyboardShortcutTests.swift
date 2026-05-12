// KeyboardShortcutTests.swift

import XCTest

/// Covers `#0093` — keyboard shortcuts must fire from terminal focus
/// (pre-`#0062` regression series). Each test cold-launches and drives
/// shortcuts after the smoke launch.
nonisolated final class KeyboardShortcutTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testCmdTCreatesNewTab() throws {
        let app = BattyUITestHarness.launchBatty()
        defer { app.terminate() }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        let chipsBefore = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'tab-chip.'")).count
        app.typeKey("t", modifierFlags: [.command])

        XCTAssertTrue(waitFor({
            app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH 'tab-chip.'")).count
                > chipsBefore
        }, timeout: 5), "Expected new tab chip after Cmd-T")
    }

    @MainActor
    func testCmdDSplitsHorizontally() throws {
        let app = BattyUITestHarness.launchBatty()
        defer { app.terminate() }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        app.typeKey("d", modifierFlags: [.command])
        XCTAssertTrue(waitFor({
            app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH 'tab-bar.'")).count
                >= 2
        }, timeout: 5))
    }

    @MainActor
    func testCmdShiftDSplitsVertically() throws {
        let app = BattyUITestHarness.launchBatty()
        defer { app.terminate() }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        app.typeKey("d", modifierFlags: [.command, .shift])
        XCTAssertTrue(waitFor({
            app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH 'tab-bar.'")).count
                >= 2
        }, timeout: 5))
    }

    @MainActor
    func testCmdWClosesTabNotWindow() throws {
        let app = BattyUITestHarness.launchBatty()
        defer { app.terminate() }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        // Open a second tab so Cmd-W has something to close other than the
        // last-tab cascade.
        app.typeKey("t", modifierFlags: [.command])
        XCTAssertTrue(waitFor({
            app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH 'tab-chip.'")).count
                >= 2
        }, timeout: 5))

        let windowCountBefore = app.windows.count
        app.typeKey("w", modifierFlags: [.command])
        // Window must still exist — Cmd-W closes the tab, not the window.
        XCTAssertEqual(app.windows.count, windowCountBefore)
    }

    @MainActor
    func testCmdShiftBracketCyclesTabs() throws {
        let app = BattyUITestHarness.launchBatty()
        defer { app.terminate() }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        app.typeKey("t", modifierFlags: [.command])
        app.typeKey("t", modifierFlags: [.command])

        // Cycle next then previous — assert no crash and at least 3 chips
        // still present.
        app.typeKey("]", modifierFlags: [.command, .shift])
        app.typeKey("[", modifierFlags: [.command, .shift])

        let count = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'tab-chip.'")).count
        XCTAssertGreaterThanOrEqual(count, 3)
    }

    private func waitFor(_ predicate: @escaping () -> Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return predicate()
    }
}
