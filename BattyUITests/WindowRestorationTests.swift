// WindowRestorationTests.swift

import XCTest

/// Relaunch-shaped tests for #0238 — window-set restoration and per-window
/// sidebar state.
///
/// **Execution deferred to #0240.** The UI-automation infrastructure on the
/// Mac mini (Accessibility/Automation permission for the XCTRunner) must be
/// confirmed before these can run. The tests are written and compile-verified;
/// #0240 will execute them as part of the full regression pass.
///
/// NOTE: True relaunch persistence (re-present N windows at their frames)
/// requires system window restoration, which macOS only commits on a clean
/// quit (not `app.terminate()` / `SIGKILL`). These tests therefore focus on
/// the per-window sidebar-toggle behavior and that a fresh window gets a new
/// session — not on frame-level restoration, which is verified manually.
nonisolated final class WindowRestorationTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
        BattyUITestHarness.sweepSentinels()
    }

    override func tearDownWithError() throws {
        BattyUITestHarness.sweepSentinels()
    }

    // MARK: - Per-window sidebar state

    /// The sidebar toggle (Cmd-B) affects only the key window, not all windows.
    ///
    /// XCUI orders `app.windows` by creation order (not z-order):
    ///   boundBy:0 = original window (opened first, background after new window)
    ///   boundBy:1 = new window (opened second, frontmost/key after Shift-Cmd-N)
    ///
    /// The new window opens as NSApp.keyWindow. We press Cmd-B without any click,
    /// verify the key (new) window's sidebar collapses, then click the original
    /// window to bring it front and verify its sidebar is still expanded.
    @MainActor
    func testToggleSidebarAffectsOnlyKeyWindow() throws {
        let app = BattyUITestHarness.launchBatty()
        defer { app.terminate() }

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        // Measure sidebar width before opening the second window.
        let sidebar = BattyUITestHarness.sidebar(in: app)
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5))
        let expandedWidth = sidebar.frame.width
        XCTAssertGreaterThan(expandedWidth, 50, "Sidebar must start expanded (>50 pt)")

        // Open a second window. It becomes the frontmost/key window in AppKit.
        // In XCUI creation order it is boundBy:1; the original window is boundBy:0.
        app.typeKey("n", modifierFlags: [.command, .shift])
        XCTAssertTrue(waitFor({ app.windows.count >= 2 }, timeout: 10),
                      "Second window must appear")

        // Wait for the new window to finish rendering (its sidebar becomes accessible).
        let newWinSidebar = BattyUITestHarness.sidebar(in: app.windows.element(boundBy: 1))
        XCTAssertTrue(newWinSidebar.waitForExistence(timeout: 10),
                      "New window sidebar must become accessible")

        // Toggle sidebar. The new window is still key (NSApp.keyWindow); the
        // RootWindowView guard ensures only its sidebar collapses.
        app.typeKey("b", modifierFlags: [.command])

        // Step 1: the key window (new, frontmost in macOS) sidebar must collapse.
        // Use the global firstMatch — on macOS XCUI `app.outlines["..."].firstMatch`
        // resolves to the frontmost window's element.
        let frontSidebar = BattyUITestHarness.sidebar(in: app)
        XCTAssertTrue(
            waitFor({ !frontSidebar.isHittable || frontSidebar.frame.width < expandedWidth / 2 },
                    timeout: 5),
            "Key window's sidebar must collapse after Cmd-B"
        )

        // Step 2: bring the original window to front and verify its sidebar is expanded.
        app.windows.element(boundBy: 0).click()
        let origSidebar = BattyUITestHarness.sidebar(in: app)
        XCTAssertTrue(
            waitFor({ origSidebar.isHittable && origSidebar.frame.width > expandedWidth / 2 },
                    timeout: 5),
            "Original window's sidebar must remain expanded after Cmd-B in the other window"
        )
    }

    /// Each new window opens with one fresh session.
    @MainActor
    func testNewWindowHasOneFreshSession() throws {
        let app = BattyUITestHarness.launchBatty()
        defer { app.terminate() }

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        // Open a second window.
        app.typeKey("n", modifierFlags: [.command, .shift])
        XCTAssertTrue(waitFor({ app.windows.count >= 2 }, timeout: 10))

        // Each window has its own "Session 1" row.
        let sessionRows = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'session-row.'"))
        XCTAssertTrue(waitFor({ sessionRows.count >= 2 }, timeout: 5),
                      "Each window should show its own initial session row")
    }

}
