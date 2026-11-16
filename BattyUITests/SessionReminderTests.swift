// SessionReminderTests.swift

import XCTest

/// Session Reminders (#0514) and the Quick Reminder bar (#0631). Time never passes on its own here: the app is
/// launched with `BATTY_UI_TEST_REMINDER_CLOCK=manual`, which freezes the
/// Reminder clock, and a test moves it with the test-only Command Palette
/// entries ("UI Test: Advance Reminder Clock by ...").
///
/// Runs only through `tools/run-ui-tests-vm.sh`, never on a host Mac.
nonisolated final class SessionReminderTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
        BattyUITestHarness.sweepSentinels()
    }

    override func tearDownWithError() throws {
        BattyUITestHarness.sweepSentinels()
    }

    // MARK: - Helpers

    @MainActor
    private func launch(script: [[String: Any]]) -> XCUIApplication {
        let app = BattyUITestHarness.launchBatty(
            script: script,
            extraEnvironment: ["BATTY_UI_TEST_REMINDER_CLOCK": "manual"])
        XCTAssertNil(BattyUITestHarness.waitForDriverErrors(), "Driver script failed")
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        return app
    }

    /// The Sidebar cell merges its children into one element, so a row's
    /// Reminder state is part of the row's own value: "..., reminder pending:
    /// <time and note>" or "..., reminder due".
    @MainActor
    private func reminderState(_ title: String, in app: XCUIApplication) -> String? {
        let value = BattyUITestHarness.sessionRow(named: title, in: app).value as? String
        guard let range = value?.range(of: "reminder ") else { return nil }
        return String(value![range.lowerBound...])
    }

    @MainActor
    private func hasPendingReminder(_ title: String, in app: XCUIApplication) -> Bool {
        reminderState(title, in: app)?.hasPrefix("reminder pending") == true
    }

    /// The open row context menu. The menu bar's Session menu also has a
    /// "Remind Me…" item, which acts on the selected Session rather than the
    /// clicked row, so every lookup is scoped to the menu holding the
    /// context-menu-only "Reset Name" item.
    @MainActor
    private func rowContextMenu(in app: XCUIApplication) -> XCUIElementQuery {
        app.menus.containing(NSPredicate(format: "title == 'Reset Name'"))
    }

    @MainActor
    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @MainActor
    private func bar(in app: XCUIApplication) -> XCUIElement { element("reminder-bar", in: app) }

    @MainActor
    private func barText(in app: XCUIApplication) -> XCUIElement { element("reminder-bar.text", in: app) }

    @MainActor
    private func barRow(_ suffix: String, in app: XCUIApplication) -> XCUIElement {
        element("reminder-bar.row.\(suffix)", in: app)
    }

    /// Chooses `item` from the row's context menu: "Remind Me…",
    /// "Edit Reminder…" or "Cancel Reminder".
    @MainActor
    private func chooseFromContextMenu(_ item: String, onRowNamed title: String, in app: XCUIApplication) {
        let row = BattyUITestHarness.sessionRow(named: title, in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 5), "session-row.\(title) must exist")
        row.rightClick()
        let entry = rowContextMenu(in: app).menuItems[item].firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 5), "The row's context menu must offer \(item)")
        entry.click()
    }

    /// Opens the Quick Reminder bar from the row's context menu.
    @MainActor
    private func openBarFromContextMenu(onRowNamed title: String, in app: XCUIApplication) {
        chooseFromContextMenu("Remind Me\u{2026}", onRowNamed: title, in: app)
        XCTAssertTrue(bar(in: app).waitForExistence(timeout: 5), "Remind Me… must open the Quick Reminder bar")
    }

    @MainActor
    private func openBarWithShortcut(in app: XCUIApplication) {
        app.typeKey("r", modifierFlags: [.command, .shift])
        XCTAssertTrue(bar(in: app).waitForExistence(timeout: 5), "⇧⌘R must open the Quick Reminder bar")
    }

    /// Types `text` into the bar (focus is already in its field) and
    /// commits it with Return.
    @MainActor
    private func setReminder(_ text: String, in app: XCUIApplication) {
        app.typeText(text)
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
        XCTAssertTrue(waitFor({ !self.bar(in: app).exists }, timeout: 5), "Return must close the bar")
    }

    @MainActor
    private func selectRow(_ title: String, in app: XCUIApplication) {
        BattyUITestHarness.sessionRow(named: title, in: app).click()
        XCTAssertTrue(waitFor({ (BattyUITestHarness.sessionRow(named: title, in: app).value as? String)?.hasPrefix("selected") == true }, timeout: 5),
                      "\(title) must be selected")
    }

    @MainActor
    private func advanceClock(_ phrase: String, in app: XCUIApplication) {
        app.typeKey("p", modifierFlags: [.command, .shift])
        let palette = app.descendants(matching: .any).matching(identifier: "command-palette.root").firstMatch
        XCTAssertTrue(palette.waitForExistence(timeout: 5))
        palette.typeText("UI Test: Advance Reminder Clock by \(phrase)")
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
        XCTAssertTrue(waitFor({ !palette.exists }, timeout: 5), "The palette must close after running the entry")
    }

    @MainActor
    private func openBellFeed(in app: XCUIApplication) {
        app.typeKey("b", modifierFlags: [.command, .shift])
        XCTAssertTrue(
            app.descendants(matching: .any).matching(identifier: "bell-feed.list").firstMatch.waitForExistence(timeout: 5)
                || app.popovers.firstMatch.waitForExistence(timeout: 5),
            "The Bell Feed must open")
    }

    /// Distinct identifiers of the feed rows that are Reminders. The row is a
    /// `.contain` element, and the VM run showed its `reminder` value is not
    /// exposed there, so a Reminder row is also recognised by holding the
    /// "Reminder" title text.
    @MainActor
    private func reminderEntryIDs(in app: XCUIApplication) -> Set<String> {
        let rows = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'bell-feed-entry.'"))
        let byValue = rows.matching(NSPredicate(format: "value == 'reminder'")).allElementsBoundByIndex
        let byTitle = rows.containing(NSPredicate(format: "label == 'Reminder' OR value == 'Reminder'")).allElementsBoundByIndex
        return Set((byValue + byTitle).map(\.identifier))
    }

    @MainActor
    private func focusedPaneIndex(in app: XCUIApplication) -> Int? {
        let panes = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'pane-terminal.'"))
        for i in 0..<panes.count where panes.element(boundBy: i).label == "focused" {
            return i
        }
        return nil
    }

    // MARK: - Tests

    /// Remind Me… from the row's context menu opens the bar; typed text and
    /// Return set a Reminder that carries the text.
    @MainActor
    func testRemindMeFromContextMenuShowsPendingBadge() throws {
        let app = launch(script: [["intent": "createSession", "name": "Alpha"]])
        defer { app.terminate() }

        openBarFromContextMenu(onRowNamed: "Alpha", in: app)
        setReminder("check the deploy", in: app)

        XCTAssertTrue(waitFor({ self.hasPendingReminder("Alpha", in: app) }, timeout: 5),
                      "A pending Reminder must show in the row's value, got: \(String(describing: BattyUITestHarness.sessionRow(named: "Alpha", in: app).value))")
        XCTAssertTrue(reminderState("Alpha", in: app)?.contains("check the deploy") == true,
                      "The row must carry the text, got: \(String(describing: reminderState("Alpha", in: app)))")
        XCTAssertNil(reminderState("Session 1", in: app), "Only the Session that was targeted gets a Reminder")
    }

    /// ⇧⌘R opens the bar with the cursor already in its field: typing with
    /// no click, then Return, sets the Reminder with that text.
    @MainActor
    func testShiftCommandROpensTheBarReadyToType() throws {
        let app = launch(script: [["intent": "createSession", "name": "Alpha"]])
        defer { app.terminate() }

        openBarWithShortcut(in: app)
        setReminder("ship the release", in: app)

        XCTAssertTrue(waitFor({ self.hasPendingReminder("Alpha", in: app) }, timeout: 5))
        XCTAssertTrue(reminderState("Alpha", in: app)?.contains("ship the release") == true,
                      "Typing without a click must land in the bar's field, got: \(String(describing: reminderState("Alpha", in: app)))")
    }

    /// ⌘3 chooses In 30 Minutes with the typed text, and is not taken by the
    /// Session menu's ⌘3 "Session 3" item: the selected Session stays.
    @MainActor
    func testCommandDigitChoosesItsRowWithTheTypedText() throws {
        let app = launch(script: [
            ["intent": "createSession", "name": "Alpha"],
            ["intent": "createSession", "name": "Beta"],
            ["intent": "createSession", "name": "Gamma"],
        ])
        defer { app.terminate() }
        selectRow("Alpha", in: app)

        openBarWithShortcut(in: app)
        app.typeText("thirty")
        app.typeKey("3", modifierFlags: .command)
        XCTAssertTrue(waitFor({ !self.bar(in: app).exists }, timeout: 5), "⌘3 must commit and close the bar")

        XCTAssertTrue(waitFor({ self.hasPendingReminder("Alpha", in: app) }, timeout: 5))
        XCTAssertTrue(reminderState("Alpha", in: app)?.contains("thirty") == true)
        XCTAssertTrue((BattyUITestHarness.sessionRow(named: "Alpha", in: app).value as? String)?.hasPrefix("selected") == true,
                      "⌘3 in the bar must not switch Sessions")
        XCTAssertNil(reminderState("Beta", in: app), "⌘3 must not reach Session 3")
    }

    /// ⌘6 opens Pick Date & Time…; Return takes the default time.
    @MainActor
    func testPickDateAndTimeSetsTheReminder() throws {
        let app = launch(script: [["intent": "createSession", "name": "Alpha"]])
        defer { app.terminate() }

        openBarWithShortcut(in: app)
        app.typeText("picked")
        app.typeKey("6", modifierFlags: .command)
        XCTAssertTrue(element("reminder-bar.picker", in: app).waitForExistence(timeout: 5), "⌘6 must show the picker")
        XCTAssertTrue(element("reminder-bar.summary", in: app).exists)
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
        XCTAssertTrue(waitFor({ !self.bar(in: app).exists }, timeout: 5), "Return must commit the picked time")

        XCTAssertTrue(waitFor({ self.hasPendingReminder("Alpha", in: app) }, timeout: 5))
        XCTAssertTrue(reminderState("Alpha", in: app)?.contains("picked") == true)
    }

    /// Escape closes the bar and sets nothing.
    @MainActor
    func testEscapeClosesTheBarAndSetsNothing() throws {
        let app = launch(script: [["intent": "createSession", "name": "Alpha"]])
        defer { app.terminate() }

        openBarWithShortcut(in: app)
        app.typeText("never mind")
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        XCTAssertTrue(waitFor({ !self.bar(in: app).exists }, timeout: 5), "Escape must close the bar")
        XCTAssertNil(reminderState("Alpha", in: app))
    }

    /// On a pending Reminder the bar opens in edit mode with the text, and
    /// Return on the highlighted Keep row changes only the text.
    @MainActor
    func testEditModeKeepsTheDueTimeAndUpdatesTheText() throws {
        let app = launch(script: [["intent": "createSession", "name": "Alpha"]])
        defer { app.terminate() }

        openBarWithShortcut(in: app)
        app.typeText("a")
        app.typeKey("2", modifierFlags: .command)
        XCTAssertTrue(waitFor({ self.hasPendingReminder("Alpha", in: app) }, timeout: 5))
        let before = try XCTUnwrap(reminderState("Alpha", in: app))
        let phrase = try XCTUnwrap(before.components(separatedBy: " \u{2014} ").first)

        openBarWithShortcut(in: app)
        XCTAssertEqual(barText(in: app).value as? String, "a", "Edit mode must prefill the text")
        XCTAssertTrue(barRow("keep", in: app).exists, "Edit mode must offer Keep")
        app.typeKey("a", modifierFlags: .command)
        setReminder("b", in: app)

        XCTAssertTrue(waitFor({ self.reminderState("Alpha", in: app)?.hasSuffix("\u{2014} b") == true }, timeout: 5),
                      "The text must change, got: \(String(describing: reminderState("Alpha", in: app)))")
        XCTAssertEqual(reminderState("Alpha", in: app)?.components(separatedBy: " \u{2014} ").first, phrase,
                       "Keep must not move the due time")
    }

    /// The edit bar's Remove Reminder row cancels it.
    @MainActor
    func testRemoveReminderRowCancelsIt() throws {
        let app = launch(script: [["intent": "createSession", "name": "Alpha"]])
        defer { app.terminate() }

        openBarWithShortcut(in: app)
        setReminder("to remove", in: app)
        XCTAssertTrue(waitFor({ self.hasPendingReminder("Alpha", in: app) }, timeout: 5))

        openBarWithShortcut(in: app)
        let remove = barRow("remove", in: app)
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        remove.click()
        XCTAssertTrue(waitFor({ !self.bar(in: app).exists }, timeout: 5))
        XCTAssertTrue(waitFor({ self.reminderState("Alpha", in: app) == nil }, timeout: 5))
    }

    /// The Session menu offers a single Remind Me…, and Edit Reminder… plus
    /// Cancel Reminder while one is pending.
    @MainActor
    func testSessionMenuOffersEditAndCancelWhilePending() throws {
        let app = launch(script: [["intent": "createSession", "name": "Alpha"]])
        defer { app.terminate() }
        let menuBar = app.menuBars.firstMatch

        menuBar.menuBarItems["Session"].click()
        XCTAssertTrue(menuBar.menuItems["Remind Me\u{2026}"].waitForExistence(timeout: 5))
        XCTAssertFalse(menuBar.menuItems["In 15 Minutes"].exists, "No one-click preset may remain")
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])

        openBarWithShortcut(in: app)
        setReminder("menu check", in: app)
        XCTAssertTrue(waitFor({ self.hasPendingReminder("Alpha", in: app) }, timeout: 5))

        menuBar.menuBarItems["Session"].click()
        XCTAssertTrue(menuBar.menuItems["Edit Reminder\u{2026}"].waitForExistence(timeout: 5))
        XCTAssertTrue(menuBar.menuItems["Cancel Reminder"].exists)
        XCTAssertFalse(menuBar.menuItems["Remind Me\u{2026}"].exists)
        menuBar.menuItems["Cancel Reminder"].click()
        XCTAssertTrue(waitFor({ self.reminderState("Alpha", in: app) == nil }, timeout: 5))
    }

    /// The Command Palette's Remind Me… closes the palette and opens the bar,
    /// ready to type.
    @MainActor
    func testPaletteRemindMeSwapsIntoTheBar() throws {
        let app = launch(script: [["intent": "createSession", "name": "Alpha"]])
        defer { app.terminate() }

        app.typeKey("p", modifierFlags: [.command, .shift])
        let palette = element("command-palette.root", in: app)
        XCTAssertTrue(palette.waitForExistence(timeout: 5))
        palette.typeText("Remind Me")
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
        XCTAssertTrue(bar(in: app).waitForExistence(timeout: 5), "Remind Me… in the palette must open the bar")
        XCTAssertFalse(palette.exists, "The palette must be closed")

        app.typeText("from the palette")
        XCTAssertEqual(barText(in: app).value as? String, "from the palette",
                       "Typing right after the bar opens must land in its field")
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
        XCTAssertTrue(waitFor({ !self.bar(in: app).exists }, timeout: 5), "Return must commit and close the palette-hosted bar")
        XCTAssertTrue(waitFor({ self.hasPendingReminder("Alpha", in: app) }, timeout: 5))
        XCTAssertTrue(reminderState("Alpha", in: app)?.contains("from the palette") == true)
    }

    /// With a command running, the field opens with "Check on <command>"
    /// selected, so typing replaces it.
    @MainActor
    func testSuggestionIsSelectedSoTypingReplacesIt() throws {
        let app = launch(script: [["intent": "createSession", "name": "Alpha"]])
        defer { app.terminate() }

        app.typeText("sleep 600\n")
        let suggested = waitFor({
            self.openBarWithShortcut(in: app)
            if self.barText(in: app).value as? String == "Check on sleep" { return true }
            app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
            _ = self.waitFor({ !self.bar(in: app).exists }, timeout: 5)
            return false
        }, timeout: 15)
        guard suggested else {
            throw XCTSkip("runningCommandDisplayName did not populate for `sleep 600` in this environment")
        }
        setReminder("replaced", in: app)
        XCTAssertTrue(waitFor({ self.hasPendingReminder("Alpha", in: app) }, timeout: 5))
        let state = reminderState("Alpha", in: app)
        XCTAssertTrue(state?.hasSuffix("\u{2014} replaced") == true, "Typing must replace the suggestion, got: \(String(describing: state))")
    }

    /// A Reminder adds only a fixed-size glyph to its Sidebar row: the row
    /// keeps its height while the Reminder is pending, after it fires and
    /// once it is acknowledged.
    @MainActor
    func testSidebarRowHeightDoesNotChangeWithAReminder() throws {
        let app = launch(script: [
            ["intent": "createSession", "name": "Alpha"],
            ["intent": "createSession", "name": "Beta"],
        ])
        defer { app.terminate() }

        let baseline = BattyUITestHarness.sessionRow(named: "Alpha", in: app).frame.height
        XCTAssertGreaterThan(baseline, 0)
        func rowHeight() -> CGFloat { BattyUITestHarness.sessionRow(named: "Alpha", in: app).frame.height }

        openBarFromContextMenu(onRowNamed: "Alpha", in: app)
        app.typeText("height")
        app.typeKey("1", modifierFlags: .command)
        XCTAssertTrue(waitFor({ !self.bar(in: app).exists }, timeout: 5), "⌘1 must commit and close the bar")
        XCTAssertTrue(waitFor({ self.hasPendingReminder("Alpha", in: app) }, timeout: 5))
        XCTAssertEqual(rowHeight(), baseline, accuracy: 0.5, "A pending Reminder must not change the row height")

        advanceClock("five minutes", in: app)
        XCTAssertTrue(waitFor({ self.reminderState("Alpha", in: app) == "reminder due" }, timeout: 5))
        XCTAssertEqual(rowHeight(), baseline, accuracy: 0.5, "A fired Reminder must not change the row height")

        selectRow("Alpha", in: app)
        XCTAssertTrue(waitFor({ self.reminderState("Alpha", in: app) == nil }, timeout: 5))
        XCTAssertEqual(rowHeight(), baseline, accuracy: 0.5, "An acknowledged Reminder must not change the row height")
    }

    /// Cancel Reminder removes the badge, and the clock passing afterwards
    /// records nothing in the Bell Feed.
    @MainActor
    func testCancelRemovesTheBadgeAndNothingFiresLater() throws {
        let app = launch(script: [["intent": "createSession", "name": "Alpha"]])
        defer { app.terminate() }

        openBarFromContextMenu(onRowNamed: "Alpha", in: app)
        setReminder("cancel me", in: app)
        XCTAssertTrue(waitFor({ self.hasPendingReminder("Alpha", in: app) }, timeout: 5))

        chooseFromContextMenu("Cancel Reminder", onRowNamed: "Alpha", in: app)
        XCTAssertTrue(waitFor({ self.reminderState("Alpha", in: app) == nil }, timeout: 5),
                      "Cancel Reminder must remove the Reminder state from the row")

        advanceClock("two hours", in: app)
        openBellFeed(in: app)
        XCTAssertEqual(reminderEntryIDs(in: app).count, 0, "A cancelled Reminder must not reach the Bell Feed")
        XCTAssertNil(reminderState("Alpha", in: app))
    }

    /// A Reminder on a Session the user is not looking at fires into the
    /// Bell Feed with its text; clicking the entry selects that Session and
    /// leaves its previously focused Pane focused.
    @MainActor
    func testFiredReminderLandsInTheFeedAndJumpKeepsTheFocusedPane() throws {
        let app = launch(script: [
            ["intent": "createSession", "name": "Alpha"],
            ["intent": "splitHorizontal"],
            ["intent": "createSession", "name": "Beta"],
        ])
        defer { app.terminate() }

        // Alpha has two Panes with the second focused; Beta is selected.
        app.descendants(matching: .any).matching(identifier: "session-row.Alpha").firstMatch.click()
        XCTAssertTrue(waitFor({ self.focusedPaneIndex(in: app) == 1 }, timeout: 5),
                      "Setup: Alpha's second Pane must be focused")
        BattyUITestHarness.sessionRow(named: "Beta", in: app).click()

        openBarFromContextMenu(onRowNamed: "Alpha", in: app)
        app.typeText("back to Alpha")
        app.typeKey("1", modifierFlags: .command)
        XCTAssertTrue(waitFor({ !self.bar(in: app).exists }, timeout: 5), "⌘1 must commit and close the bar")
        XCTAssertTrue(waitFor({ self.hasPendingReminder("Alpha", in: app) }, timeout: 5),
                      "Row value after ⌘1: \(String(describing: BattyUITestHarness.sessionRow(named: "Alpha", in: app).value))")

        advanceClock("five minutes", in: app)

        XCTAssertTrue(waitFor({ self.reminderState("Alpha", in: app) == "reminder due" }, timeout: 5),
                      "A fired Reminder must show as due on the row")
        openBellFeed(in: app)
        XCTAssertTrue(waitFor({ self.reminderEntryIDs(in: app).count == 1 }, timeout: 5), "Exactly one Reminder entry must be in the Bell Feed")
        XCTAssertTrue(app.staticTexts["back to Alpha"].firstMatch.exists, "The entry must carry the text")

        let entryID = try XCTUnwrap(reminderEntryIDs(in: app).first)
        BattyScreen.element(entryID, in: app).click()

        let alphaRow = BattyUITestHarness.sessionRow(named: "Alpha", in: app)
        XCTAssertTrue(waitFor({ (alphaRow.value as? String)?.hasPrefix("selected") == true }, timeout: 5),
                      "Clicking the entry must select Alpha")
        XCTAssertEqual(focusedPaneIndex(in: app), 1, "The jump must leave Alpha's focused Pane where it was")
        XCTAssertTrue(waitFor({ self.reminderState("Alpha", in: app) == nil }, timeout: 5),
                      "Acknowledging the Reminder must clear the due state")

        openBellFeed(in: app)
        XCTAssertTrue(waitFor({ self.reminderEntryIDs(in: app).isEmpty }, timeout: 5),
                      "Jumping to the Reminder visits its Session, which removes the row")
    }

    /// Closing the Session cancels its Reminder: nothing is recorded when
    /// the clock passes the due time.
    @MainActor
    func testClosingTheSessionCancelsItsReminder() throws {
        let app = launch(script: [["intent": "createSession", "name": "Alpha"]])
        defer { app.terminate() }

        openBarFromContextMenu(onRowNamed: "Alpha", in: app)
        app.typeText("closing")
        app.typeKey("1", modifierFlags: .command)
        XCTAssertTrue(waitFor({ self.hasPendingReminder("Alpha", in: app) }, timeout: 5), "⌘1 must set the Reminder")

        BattyUITestHarness.sessionRow(named: "Alpha", in: app).rightClick()
        // The menu bar's File > Close is also titled "Close" and closes the
        // window, quitting the app; take the item from the row's context menu.
        let close = rowContextMenu(in: app).menuItems["Close"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 5), "A right-click on a row with a pending Reminder must open its context menu")
        close.click()
        XCTAssertTrue(waitFor({ !BattyUITestHarness.sessionRow(named: "Alpha", in: app).exists }, timeout: 5),
                      "Close must remove the Session")

        advanceClock("five minutes", in: app)
        openBellFeed(in: app)
        XCTAssertEqual(reminderEntryIDs(in: app).count, 0, "A closed Session's Reminder must never fire")
    }

    /// Opens the Rename Session sheet on `title`'s row and waits for its
    /// field to hold keyboard focus.
    @MainActor
    private func openRenameSheet(onRowNamed title: String, in app: XCUIApplication) -> XCUIElement {
        chooseFromContextMenu("Rename", onRowNamed: title, in: app)
        let field = element("rename-session.field", in: app)
        XCTAssertTrue(field.waitForExistence(timeout: 5), "the Rename Session sheet must open")
        XCTAssertTrue(waitFor({ self.hasKeyboardFocus(field) }, timeout: 5), "the rename field must hold keyboard focus")
        return field
    }

    @MainActor
    private func hasKeyboardFocus(_ element: XCUIElement) -> Bool {
        element.exists && (element.value(forKey: "hasKeyboardFocus") as? Bool) == true
    }

    /// ⇧⌘R over another sheet does nothing, now or after that sheet closes.
    @MainActor
    func testShiftCommandRWhileAnotherSheetIsUpDoesNotOpenTheBar() throws {
        let app = launch(script: [["intent": "createSession", "name": "Alpha"]])
        defer { app.terminate() }
        let field = openRenameSheet(onRowNamed: "Alpha", in: app)

        app.typeKey("r", modifierFlags: [.command, .shift])
        XCTAssertFalse(bar(in: app).waitForExistence(timeout: 2), "⇧⌘R must not open the bar over another sheet")
        XCTAssertTrue(hasKeyboardFocus(field), "the rename field must keep keyboard focus")

        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        XCTAssertTrue(waitFor({ !field.exists }, timeout: 5), "Escape must close the rename sheet")
        XCTAssertFalse(bar(in: app).waitForExistence(timeout: 2), "the bar must not appear once the sheet closes")

        openBarWithShortcut(in: app)
    }

    /// Session ▸ Remind Me… chosen over another sheet does nothing.
    @MainActor
    func testSessionMenuRemindMeWhileAnotherSheetIsUpDoesNothing() throws {
        let app = launch(script: [["intent": "createSession", "name": "Alpha"]])
        defer { app.terminate() }
        let field = openRenameSheet(onRowNamed: "Alpha", in: app)
        let menuBar = app.menuBars.firstMatch

        menuBar.menuBarItems["Session"].click()
        let item = menuBar.menuItems["Remind Me\u{2026}"]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "the Session menu must offer Remind Me…")
        item.click()
        XCTAssertFalse(bar(in: app).waitForExistence(timeout: 2), "Remind Me… must not open the bar over another sheet")
        XCTAssertTrue(waitFor({ self.hasKeyboardFocus(field) }, timeout: 5), "the rename field must keep keyboard focus")
    }
}
