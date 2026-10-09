// WindowRegistrationRaceTests.swift

import XCTest

/// **Behavioural smoke test for #0437, not the regression guard.** The bug:
/// `WindowIDRegistrar` used to register a new window's `NSWindow` ↔
/// `WindowID` association via `DispatchQueue.main.async` from `updateNSView`,
/// leaving a gap — at least one main-queue turn wide — during which a
/// just-opened window could already be `NSApp.keyWindow` while still absent
/// from `AppStateStore.nsWindowMap`. During that gap Cmd-B (and every other
/// key-window-routed shortcut) found no registered key window and did
/// nothing, or a menu/CLI fallback path acted on the *previous* window
/// instead. The fix (`RegistrarNSView.viewDidMoveToWindow`) registers
/// synchronously as the view is inserted into the window's view hierarchy,
/// so no such gap can exist.
///
/// **This test almost certainly can't fail against the old, buggy code.**
/// `waitForNewWindowIdentifier` and the sidebar-existence wait below it both
/// poll through XCUITest's accessibility bridge, which round-trips through
/// many main-queue turns per check — far more than the "at least one
/// main-queue turn" the bug's gap actually spans. By the time either wait
/// resolves, the pre-fix deferred `DispatchQueue.main.async` block has
/// almost certainly already run. The real regression guard for this bug is
/// `BattyKitTests.WindowIDRegistrarTests`, which asserts registration with
/// no run-loop turn at all between `addSubview` and the check. This test's
/// job is to confirm the fixed *behavior* end-to-end (the new window's
/// sidebar collapses, Cmd-N lands in the right place) in a real app, not to
/// distinguish old code from new.
///
/// These tests deliberately do **not** wait for the new window to become
/// key/frontmost, and never click it — clicking to force key status (the
/// pattern `MultiWindowTests` and the pre-#0418 `WindowRestorationTests`
/// used) would test the wrong thing here, and #0438 found that a click is
/// unreliable in this guest's headless display besides. The only wait
/// before dispatching the shortcut is for the new window to *exist* (its
/// sidebar becomes accessible) — issue #0437's own reproduction steps are
/// "press Shift-Cmd-N, and press Cmd-B right away, without clicking."
///
/// Windows are identified by their AX `identifier`, captured before the
/// second window opens, never by `app.windows` index — #0438 found that
/// `app.windows` order is neither creation order nor a stable z-order in
/// this guest, so a `boundBy:` index can silently resolve to the wrong
/// window.
nonisolated final class WindowRegistrationRaceTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Shift-Cmd-N, then Cmd-B with no click and no wait for key/frontmost
    /// status: the new window's sidebar must collapse, and the original
    /// window's sidebar must remain expanded.
    @MainActor
    func testShiftCmdNThenImmediateCmdBCollapsesOnlyTheNewWindow() throws {
        let app = BattyUITestHarness.launchBatty()
        defer { app.terminate() }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        let sidebar = BattyUITestHarness.sidebar(in: app)
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5))
        let expandedWidth = sidebar.frame.width
        XCTAssertGreaterThan(expandedWidth, 50, "Sidebar must start expanded (>50 pt)")

        let originalWindowIdentifier = app.windows.firstMatch.identifier
        XCTAssertFalse(originalWindowIdentifier.isEmpty, "Original window must have a stable identifier")

        app.typeKey("n", modifierFlags: [.command, .shift])

        let newWindowIdentifier = waitForNewWindowIdentifier(in: app, excluding: originalWindowIdentifier)
        guard let newWindowIdentifier else {
            XCTFail("A window with an identifier different from the original must appear")
            return
        }

        let originalWindow = BattyUITestHarness.window(withIdentifier: originalWindowIdentifier, in: app)
        let newWindow = BattyUITestHarness.window(withIdentifier: newWindowIdentifier, in: app)

        // The only wait before Cmd-B: the new window's sidebar must exist.
        // No wait for boundBy:0 / key status, and no click — that gap is
        // exactly what this test exercises.
        let newWinSidebar = BattyUITestHarness.sidebar(in: newWindow)
        XCTAssertTrue(newWinSidebar.waitForExistence(timeout: 10),
                      "New window sidebar must become accessible")

        app.typeKey("b", modifierFlags: [.command])

        // Occlusion-independent checks throughout (per #0418 round 2):
        // hittability depends on cross-window covering, not on whether a
        // given window's own sidebar collapsed, so assert on !exists/exists
        // plus width rather than isHittable.
        let newWinSidebarAfterToggle = BattyUITestHarness.sidebar(in: newWindow)
        XCTAssertTrue(
            waitFor({ !newWinSidebarAfterToggle.exists || newWinSidebarAfterToggle.frame.width < expandedWidth / 2 },
                    timeout: 5),
            "New window's sidebar must collapse after an immediate, no-click Cmd-B"
        )

        let origSidebar = BattyUITestHarness.sidebar(in: originalWindow)
        XCTAssertTrue(
            waitFor({ origSidebar.exists && origSidebar.frame.width > expandedWidth / 2 },
                    timeout: 5),
            "Original window's sidebar must remain expanded — Cmd-B must not affect it, and must not be dropped for a window entirely"
        )
    }

    /// Shift-Cmd-N, then Cmd-N with no click and no wait for key/frontmost
    /// status: the new Session must land in the new window, not the
    /// original one.
    @MainActor
    func testShiftCmdNThenImmediateCmdNAddsSessionToTheNewWindow() throws {
        let app = BattyUITestHarness.launchBatty()
        defer { app.terminate() }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        let originalWindowIdentifier = app.windows.firstMatch.identifier
        XCTAssertFalse(originalWindowIdentifier.isEmpty, "Original window must have a stable identifier")
        let originalWindow = BattyUITestHarness.window(withIdentifier: originalWindowIdentifier, in: app)
        let originalRowsBefore = sessionRowCount(in: originalWindow)

        app.typeKey("n", modifierFlags: [.command, .shift])

        let newWindowIdentifier = waitForNewWindowIdentifier(in: app, excluding: originalWindowIdentifier)
        guard let newWindowIdentifier else {
            XCTFail("A window with an identifier different from the original must appear")
            return
        }
        let newWindow = BattyUITestHarness.window(withIdentifier: newWindowIdentifier, in: app)

        let newWinSidebar = BattyUITestHarness.sidebar(in: newWindow)
        XCTAssertTrue(newWinSidebar.waitForExistence(timeout: 10),
                      "New window sidebar must become accessible")
        let newRowsBefore = sessionRowCount(in: newWindow)

        app.typeKey("n", modifierFlags: [.command])

        XCTAssertTrue(
            waitFor({ self.sessionRowCount(in: newWindow) > newRowsBefore }, timeout: 5),
            "An immediate, no-click Cmd-N must add a Session to the new (key) window"
        )
        XCTAssertEqual(sessionRowCount(in: originalWindow), originalRowsBefore,
                       "Cmd-N must not misroute to the original window while the new one is meant to be key")
    }

    // MARK: - Helpers

    /// Waits for a window whose identifier differs from `excludedIdentifier`
    /// to appear, and returns that identifier. Plain iteration over
    /// already-materialized elements, not an `NSPredicate` query — per
    /// `docs/ui-testing-vm.md`'s "Known limits", the crash case is a
    /// predicate that evaluates a non-string AX value, e.g. `NSPredicate
    /// (format: "value MATCHES …")` over `.descendants(matching: .any)`
    /// hitting a `DisclosureTriangle`'s numeric `value` (#0417). `identifier`
    /// is always string-valued, so `identifier BEGINSWITH …` (used by
    /// `sessionRowCount(in:)` below) is not the same hazard; this helper
    /// avoids `NSPredicate` entirely anyway, since plain iteration over
    /// `allElementsBoundByIndex` is simplest for an exclusion check.
    @MainActor
    private func waitForNewWindowIdentifier(in app: XCUIApplication, excluding excludedIdentifier: String) -> String? {
        var found: String?
        _ = waitFor({
            for element in app.windows.allElementsBoundByIndex {
                let candidate = element.identifier
                if !candidate.isEmpty && candidate != excludedIdentifier {
                    found = candidate
                    return true
                }
            }
            return false
        }, timeout: 10, description: "a new window identifier distinct from the original")
        return found
    }

    @MainActor
    private func sessionRowCount(in window: XCUIElement) -> Int {
        window.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'session-row.'"))
            .count
    }
}
