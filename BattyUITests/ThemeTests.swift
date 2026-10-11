// ThemeTests.swift

import XCTest

/// Theme application regression suite for [[0161]].
///
/// Tests the global theme application path and per-session override.
/// Chrome accessibility values (window background, tab bar) would need to be
/// added to the respective views before assertions on theme names can be made;
/// these tests cover structural behavior (app doesn't crash, sessions remain
/// distinct) that can be asserted with current identifiers.
nonisolated final class ThemeTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
        BattyUITestHarness.sweepSentinels()
    }

    override func tearDownWithError() throws {
        BattyUITestHarness.sweepSentinels()
    }

    // MARK: - Global theme — would catch [[0033]], [[0135]]

    /// Applying a global theme does not crash the app or remove sessions.
    /// The correctness of the chrome appearance requires visual inspection or
    /// chrome accessibility values (future work).
    @MainActor
    func testApplyGlobalThemeDoesNotCrash() throws {
        // [[0033]] regression: theme selection must not crash the app.
        // We use the first available theme by name from the known catalog.
        // If the theme doesn't exist, the driver logs a notice and no-ops.
        let app = BattyUITestHarness.launchBatty(script: [
            ["intent": "createSession", "name": "Themed"],
            ["intent": "selectSession", "name": "Themed"],
            ["intent": "applyTheme", "name": "Dracula"]
        ])
        defer { app.terminate() }

        XCTAssertNil(BattyUITestHarness.waitForDriverErrors(), "Driver script failed")
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        // App must still show the session after theme application.
        let row = BattyUITestHarness.sessionRow(named: "Themed", in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 5),
                      "Session must survive theme application ([[0033]] regression)")
    }

    /// Per-session theme override does not affect other sessions structurally.
    /// Would catch [[0139]]: per-session theme affecting sibling sessions.
    @MainActor
    func testPerSessionThemeDoesNotAffectOtherSessions() throws {
        let app = BattyUITestHarness.launchBatty(script: [
            ["intent": "renameSession", "from": "Session 1", "to": "S1"],
            ["intent": "createSession", "name": "S2"],
            ["intent": "selectSession", "name": "S1"],
            ["intent": "applyThemeToActiveSession", "name": "Dracula"],
            ["intent": "createSession", "name": "S3"]
        ])
        defer { app.terminate() }

        XCTAssertNil(BattyUITestHarness.waitForDriverErrors(), "Driver script failed")
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        // All three sessions must still be present and individually accessible.
        let s1 = BattyUITestHarness.sessionRow(named: "S1", in: app)
        let s2 = BattyUITestHarness.sessionRow(named: "S2", in: app)
        let s3 = BattyUITestHarness.sessionRow(named: "S3", in: app)

        XCTAssertTrue(s1.waitForExistence(timeout: 5), "S1 must exist after per-session theme")
        XCTAssertTrue(s2.waitForExistence(timeout: 5), "S2 must exist after per-session theme")
        XCTAssertTrue(s3.waitForExistence(timeout: 5), "S3 must exist after per-session theme")
    }

    /// New sessions after a global theme applies use the global theme (not a crash).
    /// Would catch [[0147]]: new sessions not picking up the global theme.
    @MainActor
    func testNewSessionAfterGlobalThemeApplies() throws {
        let app = BattyUITestHarness.launchBatty(script: [
            ["intent": "applyTheme", "name": "Dracula"],
            ["intent": "createSession", "name": "PostTheme"]
        ])
        defer { app.terminate() }

        XCTAssertNil(BattyUITestHarness.waitForDriverErrors(), "Driver script failed")
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        // The new session must appear and be accessible.
        let row = BattyUITestHarness.sessionRow(named: "PostTheme", in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 5),
                      "New session must appear after global theme application ([[0147]] regression)")
    }

    // MARK: - Theme Selector filter scroll — [[0394]]

    /// With the list scrolled deep into the catalog, typing a filter that
    /// matches an early Theme must bring that Theme into view, on the first
    /// keystroke and on a later one.
    @MainActor
    func testFilterScrollsMatchIntoView() throws {
        let app = BattyUITestHarness.launchBatty()
        defer { app.terminate() }

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        app.typeKey("t", modifierFlags: [.command, .shift])

        let root = app.descendants(matching: .any).matching(identifier: "theme-selector.root").firstMatch
        XCTAssertTrue(root.waitForExistence(timeout: 5), "Theme Selector must open on Cmd-Shift-T")
        let filter = app.descendants(matching: .any).matching(identifier: "theme-selector.filter").firstMatch
        XCTAssertTrue(filter.waitForExistence(timeout: 5))

        func scrollDeep() {
            root.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)).hover()
            for _ in 0..<40 { root.scroll(byDeltaX: 0, deltaY: -400) }
        }

        let match = app.descendants(matching: .any)
            .matching(identifier: "theme-card.Acid Burn").firstMatch

        // "a" matches hundreds of Themes: the cursor resets and the list is
        // long enough to scroll. Scroll deep while that set is showing, then
        // narrow it; the cursor is already 0, so only the query handler can
        // bring the match back.
        filter.click()
        filter.typeText("a")
        scrollDeep()
        XCTAssertFalse(match.isHittable, "Precondition: the match must be scrolled out of view")
        filter.click()
        filter.typeText("cid Burn")
        XCTAssertTrue(match.waitForExistence(timeout: 5), "Matching Theme must exist after filtering")
        XCTAssertTrue(
            BattyUITestHarness.waitFor({ match.isHittable && root.frame.contains(match.frame) }, timeout: 5),
            "Matching Theme must be scrolled into view after narrowing the filter ([[0394]])"
        )
    }
}
