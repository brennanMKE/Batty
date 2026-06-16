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

    /// Launch with a JSON-encoded script of `UITestIntent`s. The driver
    /// dispatches them before any test assertion runs. Call
    /// `waitForDriverErrors()` before your first assertion to surface
    /// script failures clearly.
    @MainActor
    static func launchBatty(script: [[String: Any]]) -> XCUIApplication {
        guard let data = try? JSONSerialization.data(withJSONObject: script),
              let json = String(data: data, encoding: .utf8) else {
            preconditionFailure("Could not JSON-encode test script")
        }
        let app = XCUIApplication()
        app.launchEnvironment[testModeEnvVar] = "1"
        app.launchEnvironment["BATTY_UI_TEST_TEMP_HOME"] = NSTemporaryDirectory()
        app.launchEnvironment["BATTY_UI_TEST_SCRIPT"] = json
        app.launch()
        return app
    }

    /// Wait for `predicate` to become true within `timeout`. Returns `true`
    /// on success, `false` on timeout. Spins the calling thread's runloop in
    /// 50ms slices between predicate evaluations — XPC callbacks from the
    /// app under test land between slices, and the runloop stays live so
    /// the "UI unresponsiveness" warning never fires.
    ///
    /// We don't use `XCTNSPredicateExpectation` here because its block-based
    /// predicate polls at a fixed ~1Hz cadence with no public control, which
    /// is too slow for the fine-grained state changes (focus flips, chip
    /// counts) the UI tests assert on. The manual runloop spin gives us the
    /// old 50–100ms cadence without the `Thread.sleep` problem.
    @discardableResult
    nonisolated static func waitFor(
        _ predicate: @escaping () -> Bool,
        timeout: TimeInterval = 5,
        description: String = "predicate"
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            // RunLoop.run(until:) runs the runloop in default mode for the
            // full duration, processing input as it arrives. Unlike
            // `Thread.sleep`, the runloop stays live for XPC delivery.
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return predicate()
    }

    /// Run the current thread's runloop for `seconds`. Use only when no
    /// observable signal exists to wait on — predicate-based `waitFor` is
    /// strictly better whenever you can express the condition. Unlike
    /// `Thread.sleep`, this does NOT block the runloop.
    nonisolated static func pause(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    /// Poll for a driver-error sentinel. Returns the error string on failure,
    /// nil on success (no error file found within `timeout`).
    nonisolated static func waitForDriverErrors(timeout: TimeInterval = 3) -> String? {
        var found: String? = nil
        _ = waitFor({
            let fm = FileManager.default
            let tmp = NSTemporaryDirectory()
            let prefix = "batty-ui-test-driver-error-"
            if let entries = try? fm.contentsOfDirectory(atPath: tmp) {
                for entry in entries where entry.hasPrefix(prefix) {
                    let path = (tmp as NSString).appendingPathComponent(entry)
                    found = (try? String(contentsOfFile: path)) ?? "unknown driver error"
                    return true
                }
            }
            return false
        }, timeout: timeout, description: "driver error sentinel")
        return found
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
    nonisolated static func waitForFile(at path: String, timeout: TimeInterval) -> Bool {
        waitFor({
            FileManager.default.fileExists(atPath: path)
        }, timeout: timeout, description: "file at \(path)")
    }

    @MainActor
    static func sidebar(in app: XCUIApplication) -> XCUIElement {
        let collection = app.collectionViews["session-sidebar"].firstMatch
        if collection.exists { return collection }
        let outline = app.outlines["session-sidebar"].firstMatch
        if outline.exists { return outline }
        return app.descendants(matching: .any).matching(identifier: "session-sidebar").firstMatch
    }

    /// Returns the sidebar element scoped to the given window — avoids the
    /// `firstMatch` ambiguity when multiple windows are open. Pass
    /// `app.windows.element(boundBy: N)` as `window`.
    @MainActor
    static func sidebar(in window: XCUIElement) -> XCUIElement {
        let collection = window.collectionViews["session-sidebar"].firstMatch
        if collection.exists { return collection }
        let outline = window.outlines["session-sidebar"].firstMatch
        if outline.exists { return outline }
        return window.descendants(matching: .any).matching(identifier: "session-sidebar").firstMatch
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

/// Convenience forwarders so test methods can call `waitFor(...)` /
/// `pause(...)` directly without the `BattyUITestHarness.` prefix at every
/// site. Test files used to each define their own `Thread.sleep`-based
/// `waitFor` privately; centralizing in [[0170]] removed those copies.
extension XCTestCase {
    @discardableResult
    nonisolated func waitFor(
        _ predicate: @escaping () -> Bool,
        timeout: TimeInterval = 5,
        description: String = "predicate"
    ) -> Bool {
        BattyUITestHarness.waitFor(predicate, timeout: timeout, description: description)
    }

    nonisolated func pause(_ seconds: TimeInterval) {
        BattyUITestHarness.pause(seconds)
    }
}
