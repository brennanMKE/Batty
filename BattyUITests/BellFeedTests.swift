// BellFeedTests.swift

import XCTest

/// Bell feed regression suite for [[0163]].
///
/// Bell events are triggered by typing `printf '\a'` into a terminal and
/// checking for `bell-feed-entry.<id>` accessibility elements (added in
/// the [[0163]] prep). Click-to-jump tests use the entry's tap action to
/// navigate to the source pane.
///
/// Note: These tests require a real shell session in the terminal. They
/// are best run in a CI environment with a functioning shell. Tests that
/// depend on shell output use the sentinel-file pattern.
nonisolated final class BellFeedTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
        BattyUITestHarness.sweepSentinels()
    }

    override func tearDownWithError() throws {
        BattyUITestHarness.sweepSentinels()
    }

    // MARK: - Bell Feed UI baseline — would catch [[0026]]

    /// Bell Feed popover opens when the bell toolbar button is clicked.
    /// Would have caught [[0026]]: popover wiring regressions.
    @MainActor
    func testBellFeedPopoverOpens() throws {
        let app = BattyUITestHarness.launchBatty()
        defer { app.terminate() }

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        // The bell button is in the toolbar. Find it by its accessibility label.
        let bellButton = app.toolbars.buttons["Bell Feed"].firstMatch
        guard bellButton.waitForExistence(timeout: 5) else {
            // Toolbar items may not be directly accessible as buttons; try
            // descendants search.
            let btn = app.descendants(matching: .button)
                .matching(NSPredicate(format: "label CONTAINS 'Bell'")).firstMatch
            XCTAssertTrue(btn.waitForExistence(timeout: 5), "Bell Feed toolbar button not found")
            btn.click()
            XCTAssertTrue(
                waitFor({ app.descendants(matching: .any)
                    .matching(identifier: "bell-feed.list").firstMatch.exists ||
                    app.popovers.firstMatch.exists }, timeout: 5),
                "Bell Feed popover must appear on toolbar button click ([[0026]] regression)"
            )
            return
        }
        bellButton.click()
        XCTAssertTrue(
            waitFor({ app.popovers.firstMatch.exists }, timeout: 5),
            "Bell Feed popover must appear on toolbar button click ([[0026]] regression)"
        )
    }

    // MARK: - Bell capture — would catch [[0024]], [[0025]]

    /// A BEL from a Pane the user isn't looking at produces a feed entry.
    /// Would have caught [[0024]]: bell capture not wired up. The bell rings
    /// from an unfocused Pane because a bell from the focused Tab while Batty
    /// is frontmost adds no entry. The gate file keeps the BEL from ringing
    /// before focus has moved back to the first Pane.
    @MainActor
    func testBellByteProducesFeedEntry() throws {
        let scratch = try BattyCLI.makeScratchDirectory()
        let (app, _, initial) = try BattyCLI.launchConnected(from: Self.self)
        defer { app.terminate() }

        let session = try XCTUnwrap(initial.selectedSession)
        let original = session.focusedPaneID
        let gate = BattyUITestHarness.sentinelPath(named: "bell-gate")
        let rang = BattyUITestHarness.sentinelPath(named: "bell-rang")
        let script = try BattyCLI.makeScript(
            in: scratch,
            named: "ring.sh",
            body: "while [ ! -e \(BattyCLI.shellQuoted(gate)) ]; do sleep 0.1; done; printf '\\a'; touch \(BattyCLI.shellQuoted(rang)); exec sleep 600"
        )
        BattyCLI.runExpectingSuccess(["pane", "split", "-h", "--pane", original.uuidString, "--command", script])
        BattyCLI.runExpectingSuccess(["pane", "focus", original.uuidString])
        _ = try XCTUnwrap(BattyCLI.waitForTopology { $0.session(session.id)?.focusedPaneID == original }, "focus did not return to the first Pane")

        BattyScreen.openBellFeed(in: app)
        XCTAssertEqual(BattyScreen.bellEntryIDs(in: app).count, 0)

        XCTAssertTrue(FileManager.default.createFile(atPath: gate, contents: nil))
        XCTAssertTrue(BattyUITestHarness.waitForFile(at: rang, timeout: 15), "the script never rang the bell")

        XCTAssertTrue(
            waitFor({ BattyScreen.bellEntryIDs(in: app).count == 1 }, timeout: 10),
            "A BEL byte must produce one bell-feed-entry ([[0024]] regression)"
        )
        let entryID = try XCTUnwrap(BattyScreen.bellEntryIDs(in: app).first)
        let path = BattyScreen.element("bell-feed-path.\(entryID)", in: app)
        XCTAssertTrue(path.waitForExistence(timeout: 10))
        let label = path.label.isEmpty ? ((path.value as? String) ?? "") : path.label
        XCTAssertTrue(label.contains("Pane 2"), "the entry must name the ringing Pane, saw \(label)")
    }

    // MARK: - Bell cleared on navigation — would catch [[0069]]

    /// Visiting a Tab removes its rows from the Feed (#0556): a Feed row
    /// click removes that Tab's row, and a Sidebar click removes the other.
    /// Would have caught [[0069]]: notifications didn't clear on navigation.
    @MainActor
    func testBellClearsOnNavigation() throws {
        let (app, _, initial) = try BattyCLI.launchConnected(from: Self.self)
        defer { app.terminate() }
        let first = try XCTUnwrap(initial.selectedSession)
        let scratch = try BattyCLI.makeScratchDirectory()
        let dirB = scratch.appending(path: "visit-b")
        let dirC = scratch.appending(path: "visit-c")
        try FileManager.default.createDirectory(at: dirB, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dirC, withIntermediateDirectories: true)
        let (sessionB, paneB) = try BattyCLI.newSession(at: dirB)
        let (sessionC, paneC) = try BattyCLI.newSession(at: dirC)
        let tabB = try XCTUnwrap(sessionB.pane(paneB)?.activeTabID)
        let tabC = try XCTUnwrap(sessionC.pane(paneC)?.activeTabID)
        BattyCLI.runExpectingSuccess(["session", "focus", first.id.uuidString])
        _ = try XCTUnwrap(BattyCLI.waitForTopology { $0.selectedSessionID == first.id }, "session focus did not select the first Session")

        BattyCLI.runExpectingSuccess(["notify", "--title", "visit me", "--tab", tabB.uuidString])
        BattyCLI.runExpectingSuccess(["notify", "--title", "keep me", "--tab", tabC.uuidString])

        BattyScreen.openBellFeed(in: app)
        XCTAssertTrue(waitFor({ BattyScreen.bellEntryIDs(in: app).count == 2 }, timeout: 10), "the two notifications did not both reach the Feed")
        let visitID = try XCTUnwrap(BattyScreen.bellEntryIDs(in: app).first { entryID in
            Self.text(of: BattyScreen.element("bell-feed-message.\(entryID)", in: app)) == "visit me"
        }, "no \"visit me\" row")
        BattyScreen.element("bell-feed-message.\(visitID)", in: app).click()
        _ = try XCTUnwrap(BattyCLI.waitForTopology { $0.selectedSessionID == sessionB.id }, "the Feed click did not select Session B")

        BattyScreen.openBellFeed(in: app)
        XCTAssertTrue(waitFor({ BattyScreen.bellEntryIDs(in: app).count == 1 }, timeout: 10), "the visited Tab's row is still in the Feed")
        let keptID = try XCTUnwrap(BattyScreen.bellEntryIDs(in: app).first)
        XCTAssertEqual(Self.text(of: BattyScreen.element("bell-feed-message.\(keptID)", in: app)), "keep me")
        app.typeKey(.escape, modifierFlags: [])

        let rowC = BattyUITestHarness.sessionRow(named: sessionC.name, in: app)
        XCTAssertTrue(rowC.waitForExistence(timeout: 10), "no Sidebar row for Session C")
        rowC.click()
        _ = try XCTUnwrap(BattyCLI.waitForTopology { $0.selectedSessionID == sessionC.id }, "the Sidebar click did not select Session C")

        BattyScreen.openBellFeed(in: app)
        XCTAssertTrue(waitFor({ app.staticTexts["No bell events"].exists && BattyScreen.bellEntryIDs(in: app).isEmpty }, timeout: 10),
                      "the Sidebar visit did not remove Session C's row")
    }

    // MARK: - Muted Session (#0558)

    /// A muted Session's `batty notify` adds no Bell Feed row, and unmuting
    /// brings nothing back. The absence check is not a race: the CLI's
    /// `notify` reply arrives only after `recordCLINotification` returned,
    /// and `runExpectingSuccess` waits for the CLI to exit.
    @MainActor
    func testMutedSessionNotifyAddsNoFeedEntry() throws {
        let (app, _, initial) = try BattyCLI.launchConnected(from: Self.self)
        let first = try XCTUnwrap(initial.selectedSession)
        let directory = try BattyCLI.makeScratchDirectory().appending(path: "muted-project")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let (second, secondPane) = try BattyCLI.newSession(at: directory)
        let secondTab = try XCTUnwrap(second.pane(secondPane)?.activeTabID)
        BattyCLI.runExpectingSuccess(["session", "focus", first.id.uuidString])
        _ = try XCTUnwrap(BattyCLI.waitForTopology { $0.selectedSessionID == first.id }, "session focus did not select the first Session")

        toggleMute("Mute Notifications", onRowNamed: second.name, in: app)
        BattyScreen.openBellFeed(in: app)
        BattyCLI.runExpectingSuccess(["notify", "--title", "muted", "--tab", secondTab.uuidString])
        XCTAssertEqual(BattyScreen.bellEntryIDs(in: app).count, 0, "a muted Session's notify must add no Bell Feed row")

        app.typeKey(.escape, modifierFlags: [])
        toggleMute("Unmute Notifications", onRowNamed: second.name, in: app)
        BattyScreen.openBellFeed(in: app)
        BattyCLI.runExpectingSuccess(["notify", "--title", "unmuted", "--tab", secondTab.uuidString])
        XCTAssertTrue(BattyUITestHarness.waitFor({ BattyScreen.bellEntryIDs(in: app).count == 1 }, timeout: 10),
                      "after unmuting, exactly the new notify must be listed")
    }

    /// Context-menu identifiers don't reach XCUITest, so the item is found
    /// by title in the row's menu, which is the one holding "Reset Name".
    @MainActor
    private func toggleMute(_ title: String, onRowNamed name: String, in app: XCUIApplication) {
        let row = BattyUITestHarness.sessionRow(named: name, in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 5), "session-row.\(name) must exist")
        row.rightClick()
        let item = app.menus.containing(NSPredicate(format: "title == 'Reset Name'")).menuItems[title].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), "the row's context menu must offer \(title)")
        item.click()
    }

    /// The text a Text exposes: its label, else its value.
    @MainActor
    private static func text(of element: XCUIElement) -> String {
        if !element.label.isEmpty { return element.label }
        if let value = element.value as? String, !value.isEmpty { return value }
        return element.title
    }

    // MARK: - Helpers
}
