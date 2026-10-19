// BellFeedRatingTests.swift

import XCTest

/// Bell Feed row rating menu (#0524). Runs only in the Tart VM
/// (`tools/run-ui-tests-vm.sh`). Capture is switched with the command-line
/// defaults override so no persistent preference changes. Entries come from
/// `batty notify` aimed at a background Session, the same route
/// `CLIBackgroundSessionTests` uses, which also leaves them unseen.
nonisolated final class BellFeedRatingTests: XCTestCase {
    private static let captureKey = "-co.sstools.Batty.captureBellFeedData"
    private var scratch: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        BattyUITestHarness.sweepSentinels()
        scratch = try BattyCLI.makeScratchDirectory()
    }

    override func tearDownWithError() throws {
        BattyUITestHarness.sweepSentinels()
    }

    private struct Fixture {
        let app: XCUIApplication
        let entry: XCUIElement
        let entryID: String
    }

    /// Launches with capture on or off, creates a second Session, selects the
    /// first, opens the Bell Feed and notifies the second Session's Tab, so
    /// the one entry is unseen.
    @MainActor
    private func launchWithUnseenEntry(capture: Bool) throws -> Fixture {
        let (app, _, initial) = try BattyCLI.launchConnected(
            from: Self.self,
            extraArguments: [Self.captureKey, capture ? "YES" : "NO"]
        )
        let first = try XCTUnwrap(initial.selectedSession)
        let directory = scratch.appending(path: "rating-project")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let (second, secondPane) = try BattyCLI.newSession(at: directory)
        let secondTab = try XCTUnwrap(second.pane(secondPane)?.activeTabID)
        BattyCLI.runExpectingSuccess(["session", "focus", first.id.uuidString])
        _ = try XCTUnwrap(BattyCLI.waitForTopology { $0.selectedSessionID == first.id }, "session focus did not select the first Session")
        BattyScreen.openBellFeed(in: app)
        BattyCLI.runExpectingSuccess(["notify", "--title", "rating test", "--tab", secondTab.uuidString])
        XCTAssertTrue(BattyUITestHarness.waitFor({ BattyScreen.bellEntryIDs(in: app).count == 1 }, timeout: 10), "notify added no Bell Feed entry")
        let entryID = try XCTUnwrap(BattyScreen.bellEntryIDs(in: app).first)
        return Fixture(app: app, entry: BattyScreen.element("bell-feed-entry.\(entryID)", in: app), entryID: entryID)
    }

    @MainActor
    private func openEditor(_ f: Fixture) -> XCUIElement {
        f.entry.rightClick()
        let item = f.app.menuItems["Suggest Better Text…"]
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        XCTAssertTrue(item.isEnabled)
        item.click()
        let field = BattyScreen.element("bell-feed.suggest.field", in: f.app)
        XCTAssertTrue(field.waitForExistence(timeout: 5), "the suggestion editor must open")
        return field
    }

    @MainActor
    private func waitForEditorFocus(_ field: XCUIElement, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let id = "bell-feed.suggest.field"
        XCTAssertTrue(
            BattyUITestHarness.waitFor({
                [field, app.textFields[id], app.textViews[id]].contains { element in
                    element.exists && (element.value(forKey: "hasKeyboardFocus") as? Bool) == true
                }
            }, timeout: 5),
            "the suggestion field must hold keyboard focus when the editor opens",
            file: file,
            line: line
        )
    }

    @MainActor
    func testVerdictCheckmarkMovesBetweenGoodAndBad() throws {
        let f = try launchWithUnseenEntry(capture: true)
        defer { f.app.terminate() }
        let app = f.app

        f.entry.rightClick()
        // XCUITest reports no checked state for these menu items, so the
        // selected verdict is exposed as a ".selected" identifier suffix.
        let good = app.menuItems["bell-feed.rating.good"]
        XCTAssertTrue(good.waitForExistence(timeout: 5))
        XCTAssertTrue(good.isEnabled)
        XCTAssertFalse(app.menuItems["bell-feed.rating.bad.selected"].exists)
        good.click()

        f.entry.rightClick()
        XCTAssertTrue(app.menuItems["bell-feed.rating.good.selected"].waitForExistence(timeout: 5), "Good Summary must be selected after choosing it")
        XCTAssertFalse(app.menuItems["bell-feed.rating.bad.selected"].exists)
        app.menuItems["bell-feed.rating.bad"].click()

        f.entry.rightClick()
        XCTAssertTrue(app.menuItems["bell-feed.rating.bad.selected"].waitForExistence(timeout: 5), "the selection must move to Bad Summary")
        XCTAssertFalse(app.menuItems["bell-feed.rating.good.selected"].exists)
        app.typeKey(.escape, modifierFlags: [])
    }

    @MainActor
    func testSuggestBetterTextSaveAndCancelBothCloseTheEditor() throws {
        let f = try launchWithUnseenEntry(capture: true)
        defer { f.app.terminate() }
        let app = f.app

        let field = openEditor(f)
        field.click()
        app.typeKey("a", modifierFlags: .command)
        app.typeText("Rating test passed")
        let save = BattyScreen.element("bell-feed.suggest.save", in: app)
        XCTAssertTrue(save.isEnabled)
        save.click()
        XCTAssertTrue(BattyUITestHarness.waitFor({ !field.exists }, timeout: 5), "Save must close the editor")

        _ = openEditor(f)
        BattyScreen.element("bell-feed.suggest.cancel", in: app).click()
        XCTAssertTrue(BattyUITestHarness.waitFor({ !field.exists }, timeout: 5), "Cancel must close the editor")
    }

    @MainActor
    func testEditorTakesFocusOnOpenReturnSavesAndEscapeCancels() throws {
        let f = try launchWithUnseenEntry(capture: true)
        defer { f.app.terminate() }
        let app = f.app

        let field = openEditor(f)
        waitForEditorFocus(field, in: app)
        app.typeText("Typed without clicking the field")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(BattyUITestHarness.waitFor({ !field.exists }, timeout: 5), "Return must save and close the editor")
        XCTAssertTrue(app.popovers.firstMatch.exists, "saving must leave the Bell Feed open")

        let reopened = openEditor(f)
        waitForEditorFocus(reopened, in: app)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(BattyUITestHarness.waitFor({ !field.exists }, timeout: 5), "Escape must close the editor")
        XCTAssertTrue(app.popovers.firstMatch.exists, "Escape in the editor must not dismiss the Bell Feed")
    }

    @MainActor
    func testSaveIsDisabledForWhitespaceOnlyText() throws {
        let f = try launchWithUnseenEntry(capture: true)
        defer { f.app.terminate() }
        let app = f.app

        let field = openEditor(f)
        field.click()
        app.typeKey("a", modifierFlags: .command)
        app.typeText("   ")
        XCTAssertFalse(BattyScreen.element("bell-feed.suggest.save", in: app).isEnabled)
        BattyScreen.element("bell-feed.suggest.cancel", in: app).click()
    }

    @MainActor
    func testCaptureOffHidesTheRatingItems() throws {
        let f = try launchWithUnseenEntry(capture: false)
        defer { f.app.terminate() }
        let app = f.app

        f.entry.rightClick()
        BattyUITestHarness.pause(0.5)
        XCTAssertFalse(app.menuItems["Good Summary"].exists)
        XCTAssertFalse(app.menuItems["Bad Summary"].exists)
        XCTAssertFalse(app.menuItems["Suggest Better Text…"].exists)
        app.typeKey(.escape, modifierFlags: [])
    }

    @MainActor
    func testRightClickAndRatingLeaveTheEntryUnseen() throws {
        let f = try launchWithUnseenEntry(capture: true)
        defer { f.app.terminate() }
        let app = f.app
        // The dot's identifier encodes its state: bell-feed-unseen.<id> or bell-feed-seen.<id>.
        let unseen = BattyScreen.element("bell-feed-unseen.\(f.entryID)", in: app)
        let seen = BattyScreen.element("bell-feed-seen.\(f.entryID)", in: app)

        XCTAssertTrue(unseen.waitForExistence(timeout: 5), "an unseen entry must expose the unseen indicator")
        XCTAssertFalse(seen.exists)

        f.entry.rightClick()
        XCTAssertTrue(app.menuItems["bell-feed.rating.good"].waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(unseen.exists, "opening the context menu must not mark the entry seen")
        XCTAssertFalse(seen.exists)
        XCTAssertTrue(app.popovers.firstMatch.exists, "right-click must not jump or dismiss the popover")

        f.entry.rightClick()
        app.menuItems["bell-feed.rating.good"].click()
        XCTAssertTrue(unseen.exists, "rating must not mark the entry seen")
        XCTAssertFalse(seen.exists)
        XCTAssertTrue(app.popovers.firstMatch.exists)
    }
}
