// BattyUITestHarness.swift

import Foundation
import XCTest

/// Helpers shared by every test in this target. Keeps the per-test setup
/// short and the boilerplate (launch flag, sentinel cleanup, common
/// element lookups) in one place.
nonisolated enum BattyUITestHarness {
    /// Environment variable read by `QuitConfirmation.isInUITestMode` to
    /// short-circuit the modal alert. `xcodebuild test` can't dismiss a
    /// modal so without this the run hangs at teardown.
    static let testModeEnvVar = "BATTY_UI_TEST_MODE"

    /// Build a configured `XCUIApplication`, set the bypass flag, and
    /// launch it. Callers receive a launched app ready to assert against.
    @MainActor
    static func launchBatty() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment[testModeEnvVar] = "1"
        app.launchEnvironment["BATTY_UI_TEST_TEMP_HOME"] = NSTemporaryDirectory()
        app.launch()
        return app
    }

    /// Remove `/tmp/batty-ui-test-*` sentinel files that a test may have
    /// touched. Idempotent.
    static func sweepSentinels() {
        let fm = FileManager.default
        let tmp = NSTemporaryDirectory()
        let prefix = "batty-ui-test-"
        if let entries = try? fm.contentsOfDirectory(atPath: tmp) {
            for entry in entries where entry.hasPrefix(prefix) {
                try? fm.removeItem(atPath: (tmp as NSString).appendingPathComponent(entry))
            }
        }
    }

    /// Path to a fresh sentinel file for the named slot. Returns the
    /// absolute path the shell can write to and the test can poll.
    static func sentinelPath(named name: String) -> String {
        let unique = UUID().uuidString.prefix(8)
        return (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("batty-ui-test-\(name)-\(unique)")
    }

    /// Poll-wait for the file at `path` to exist. Returns true on success;
    /// false on timeout.
    static func waitForFile(at path: String, timeout: TimeInterval) -> Bool {
        let fm = FileManager.default
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if fm.fileExists(atPath: path) {
                return true
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return fm.fileExists(atPath: path)
    }

    @MainActor
    static func sidebar(in app: XCUIApplication) -> XCUIElement {
        app.collectionViews["session-sidebar"].firstMatch
    }

    @MainActor
    static func sessionRow(named title: String, in app: XCUIApplication) -> XCUIElement {
        let identifier = "session-row.\(title)"
        let cell = app.collectionViews.cells[identifier].firstMatch
        if cell.exists { return cell }
        return app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @MainActor
    static func tabChip(named title: String, in app: XCUIApplication) -> XCUIElement {
        let identifier = "tab-chip.\(title)"
        return app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }
}
