// TabChipRenderingTests.swift

import XCTest

/// Tab chip rendering regression suite for [[0164]].
///
/// Asserts chip uniqueness and basic structure. Frame-based assertions
/// (chip overflow, add-button reachability) use the accessibility frame
/// API and require a running, visible app window.
nonisolated final class TabChipRenderingTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
        BattyUITestHarness.sweepSentinels()
    }

    override func tearDownWithError() throws {
        BattyUITestHarness.sweepSentinels()
    }

    // MARK: - Per-tab title uniqueness — would catch [[0050]]

    /// Three sessions with distinct names produce three distinct session rows.
    /// (The tab chip uniqueness test mirrors this for tabs.)
    @MainActor
    func testThreeSessionsHaveDistinctRowIdentifiers() throws {
        // [[0050]]: chips all showed same user@host — verify per-entity identity.
        let app = BattyUITestHarness.launchBatty(script: [
            ["intent": "renameSession", "from": "Session 1", "to": "Alpha"],
            ["intent": "createSession", "name": "Beta"],
            ["intent": "createSession", "name": "Gamma"]
        ])
        defer { app.terminate() }

        XCTAssertNil(BattyUITestHarness.waitForDriverErrors(), "Driver script failed")
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        let alpha = BattyUITestHarness.sessionRow(named: "Alpha", in: app)
        let beta = BattyUITestHarness.sessionRow(named: "Beta", in: app)
        let gamma = BattyUITestHarness.sessionRow(named: "Gamma", in: app)

        XCTAssertTrue(alpha.waitForExistence(timeout: 5), "Alpha row must exist")
        XCTAssertTrue(beta.waitForExistence(timeout: 5), "Beta row must exist")
        XCTAssertTrue(gamma.waitForExistence(timeout: 5), "Gamma row must exist")
    }

    /// Two tabs renamed to different names produce distinct chip identifiers.
    @MainActor
    func testTwoRenamedTabsHaveDistinctChipIdentifiers() throws {
        // [[0050]] regression: if chip identifiers collide, assertion fails.
        let app = BattyUITestHarness.launchBatty(script: [
            ["intent": "renameActiveTab", "to": "TabAlpha"],
            ["intent": "createTab"],
            ["intent": "renameActiveTab", "to": "TabBeta"]
        ])
        defer { app.terminate() }

        XCTAssertNil(BattyUITestHarness.waitForDriverErrors(), "Driver script failed")
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        let chipAlpha = app.descendants(matching: .any)
            .matching(identifier: "tab-chip.TabAlpha").firstMatch
        let chipBeta = app.descendants(matching: .any)
            .matching(identifier: "tab-chip.TabBeta").firstMatch

        XCTAssertTrue(chipAlpha.waitForExistence(timeout: 5),
                      "tab-chip.TabAlpha must exist ([[0050]] regression)")
        XCTAssertTrue(chipBeta.waitForExistence(timeout: 5),
                      "tab-chip.TabBeta must exist ([[0050]] regression)")
    }

    // MARK: - Tab bar stays inside pane bounds — would catch [[0047]]

    /// Tab bar frame width must not exceed its pane's terminal frame width.
    @MainActor
    func testTabBarWidthDoesNotExceedPaneWidth() throws {
        // [[0047]]: tab bar contents rendered past the pane's trailing edge.
        let app = BattyUITestHarness.launchBatty(script: [
            ["intent": "renameActiveTab", "to": "T1"],
            ["intent": "createTab"],
            ["intent": "renameActiveTab", "to": "T2"],
            ["intent": "createTab"],
            ["intent": "renameActiveTab", "to": "T3"]
        ])
        defer { app.terminate() }

        XCTAssertNil(BattyUITestHarness.waitForDriverErrors(), "Driver script failed")
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        let tabBars = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'tab-bar.'"))
        let panes = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'pane-terminal.'"))

        XCTAssertTrue(waitFor({ tabBars.count >= 1 && panes.count >= 1 }, timeout: 10))

        let tabBarFrame = tabBars.element(boundBy: 0).frame
        let paneFrame = panes.element(boundBy: 0).frame

        XCTAssertLessThanOrEqual(
            tabBarFrame.maxX, paneFrame.maxX + 2,
            "Tab bar trailing edge must not exceed pane trailing edge ([[0047]] regression)"
        )
    }

    // MARK: - Home dir tab shows "~" by default — [[0142]] default case

    /// A fresh tab (likely at $HOME) shows a non-empty chip title.
    @MainActor
    func testDefaultTabHasNonEmptyChipTitle() throws {
        // [[0142]]: verify the home-dir "~" default renders as a valid chip identifier.
        let app = BattyUITestHarness.launchBatty()
        defer { app.terminate() }

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        let chips = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'tab-chip.'"))
        XCTAssertTrue(waitFor({ chips.count >= 1 }, timeout: 5),
                      "At least one tab chip must be visible on cold launch")

        for i in 0..<chips.count {
            let id = chips.element(boundBy: i).identifier
            XCTAssertTrue(id.count > "tab-chip.".count,
                          "Chip identifier must not be empty (tab-chip. only)")
        }
    }
}

extension TabChipRenderingTests {}
