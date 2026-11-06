// SessionReminderTests.swift

import XCTest

/// Session Reminders (#0514). Time never passes on its own here: the app is
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
    /// "Remind Me" item, which acts on the selected Session rather than the
    /// clicked row, so every lookup is scoped to the menu holding the
    /// context-menu-only "Reset Name" item.
    @MainActor
    private func rowContextMenu(in app: XCUIApplication) -> XCUIElementQuery {
        app.menus.containing(NSPredicate(format: "title == 'Reset Name'"))
    }

    @MainActor
    @discardableResult
    private func openRemindMeMenu(onRowNamed title: String, in app: XCUIApplication) -> XCUIElement {
        let row = BattyUITestHarness.sessionRow(named: title, in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 5), "session-row.\(title) must exist")
        row.rightClick()
        let remind = rowContextMenu(in: app).menuItems["Remind Me"].firstMatch
        XCTAssertTrue(remind.waitForExistence(timeout: 5), "The row's context menu must offer Remind Me")
        remind.click()
        return remind
    }

    @MainActor
    private func chooseFromRemindMe(_ item: String, onRowNamed title: String, in app: XCUIApplication) {
        let remind = openRemindMeMenu(onRowNamed: title, in: app)
        let entry = remind.menuItems[item].firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 5), "Remind Me must offer \(item)")
        entry.click()
    }

    /// Replaces the Hours and Minutes fields' text rather than appending to
    /// their "0", and commits each number with Tab.
    @MainActor
    private func setCustomDuration(hours: String, minutes: String, in app: XCUIApplication) {
        let hoursField = app.descendants(matching: .any).matching(identifier: "reminder-sheet.custom.hours").firstMatch
        let minutesField = app.descendants(matching: .any).matching(identifier: "reminder-sheet.custom.minutes").firstMatch
        hoursField.click()
        hoursField.typeKey("a", modifierFlags: .command)
        hoursField.typeText("\(hours)\t")
        minutesField.click()
        minutesField.typeKey("a", modifierFlags: .command)
        minutesField.typeText("\(minutes)\t")
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

    /// Remind Me > In 15 Minutes from the row's context menu sets the
    /// Reminder at once and puts the clock badge on the row.
    @MainActor
    func testRemindMeFromContextMenuShowsPendingBadge() throws {
        let app = launch(script: [["intent": "createSession", "name": "Alpha"]])
        defer { app.terminate() }

        chooseFromRemindMe("In 15 Minutes", onRowNamed: "Alpha", in: app)

        XCTAssertTrue(waitFor({ self.hasPendingReminder("Alpha", in: app) }, timeout: 5),
                      "A pending Reminder must show in the row's value, got: \(String(describing: BattyUITestHarness.sessionRow(named: "Alpha", in: app).value))")
        XCTAssertNil(reminderState("Session 1", in: app), "Only the Session that was targeted gets a Reminder")
    }

    /// Custom... opens the sheet; 1 h 30 m with a note sets a Reminder whose
    /// badge carries the note.
    @MainActor
    func testCustomSheetWithANoteSetsTheReminder() throws {
        let app = launch(script: [["intent": "createSession", "name": "Alpha"]])
        defer { app.terminate() }

        chooseFromRemindMe("Custom\u{2026}", onRowNamed: "Alpha", in: app)

        let sheet = app.descendants(matching: .any).matching(identifier: "reminder-sheet").firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), "Custom... must open the Reminder sheet")
        let hours = app.descendants(matching: .any).matching(identifier: "reminder-sheet.custom.hours").firstMatch
        let minutes = app.descendants(matching: .any).matching(identifier: "reminder-sheet.custom.minutes").firstMatch
        // Replace the field's "0" rather than append to it, and commit each
        // number with Tab before moving on.
        _ = (hours, minutes)
        setCustomDuration(hours: "1", minutes: "30", in: app)
        let note = app.descendants(matching: .any).matching(identifier: "reminder-sheet.note").firstMatch
        note.click()
        note.typeText("review the deploy")
        let set = app.descendants(matching: .any).matching(identifier: "reminder-sheet.set").firstMatch
        XCTAssertTrue(set.isEnabled, "1 h 30 m is a valid duration, so Set must be enabled")
        set.click()

        XCTAssertTrue(waitFor({ !set.exists }, timeout: 5), "Set Reminder must close the sheet")
        XCTAssertTrue(waitFor({ self.hasPendingReminder("Alpha", in: app) }, timeout: 5))
        XCTAssertTrue(reminderState("Alpha", in: app)?.contains("review the deploy") == true,
                      "The row must carry the note, got: \(String(describing: reminderState("Alpha", in: app)))")
    }

    /// Cancel Reminder removes the badge, and the clock passing afterwards
    /// records nothing in the Bell Feed.
    @MainActor
    func testCancelRemovesTheBadgeAndNothingFiresLater() throws {
        let app = launch(script: [["intent": "createSession", "name": "Alpha"]])
        defer { app.terminate() }

        chooseFromRemindMe("In 15 Minutes", onRowNamed: "Alpha", in: app)
        XCTAssertTrue(waitFor({ self.hasPendingReminder("Alpha", in: app) }, timeout: 5))

        chooseFromRemindMe("Cancel Reminder", onRowNamed: "Alpha", in: app)
        XCTAssertTrue(waitFor({ self.reminderState("Alpha", in: app) == nil }, timeout: 5),
                      "Cancel Reminder must remove the Reminder state from the row")

        advanceClock("two hours", in: app)
        openBellFeed(in: app)
        XCTAssertEqual(reminderEntryIDs(in: app).count, 0, "A cancelled Reminder must not reach the Bell Feed")
        XCTAssertNil(reminderState("Alpha", in: app))
    }

    /// A Reminder on a Session the user is not looking at fires into the
    /// Bell Feed with its note; clicking the entry selects that Session and
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

        chooseFromRemindMe("Custom\u{2026}", onRowNamed: "Alpha", in: app)
        let sheet = app.descendants(matching: .any).matching(identifier: "reminder-sheet").firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        setCustomDuration(hours: "0", minutes: "5", in: app)
        let note = app.descendants(matching: .any).matching(identifier: "reminder-sheet.note").firstMatch
        note.click()
        note.typeText("back to Alpha")
        let set = app.descendants(matching: .any).matching(identifier: "reminder-sheet.set").firstMatch
        XCTAssertTrue(set.isEnabled, "0 h 5 m is a valid duration, so Set must be enabled")
        set.click()
        XCTAssertTrue(waitFor({ !set.exists }, timeout: 5), "Set Reminder must close the sheet")
        XCTAssertTrue(waitFor({ self.hasPendingReminder("Alpha", in: app) }, timeout: 5),
                      "Row value after Set: \(String(describing: BattyUITestHarness.sessionRow(named: "Alpha", in: app).value))")

        advanceClock("five minutes", in: app)

        XCTAssertTrue(waitFor({ self.reminderState("Alpha", in: app) == "reminder due" }, timeout: 5),
                      "A fired Reminder must show as due on the row")
        openBellFeed(in: app)
        XCTAssertTrue(waitFor({ self.reminderEntryIDs(in: app).count == 1 }, timeout: 5), "Exactly one Reminder entry must be in the Bell Feed")
        XCTAssertTrue(app.staticTexts["back to Alpha"].firstMatch.exists, "The entry must carry the note")

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

    /// A sheet preset selects its duration and Set creates the Reminder.
    @MainActor
    func testSheetPresetSetsAReminder() throws {
        let app = launch(script: [["intent": "createSession", "name": "Alpha"]])
        defer { app.terminate() }

        chooseFromRemindMe("Custom\u{2026}", onRowNamed: "Alpha", in: app)
        let sheet = app.descendants(matching: .any).matching(identifier: "reminder-sheet").firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        app.descendants(matching: .any).matching(identifier: "reminder-sheet.preset.30").firstMatch.click()
        let set = app.descendants(matching: .any).matching(identifier: "reminder-sheet.set").firstMatch
        XCTAssertTrue(set.isEnabled)
        set.click()
        XCTAssertTrue(waitFor({ !set.exists }, timeout: 5), "Set Reminder must close the sheet")
        XCTAssertTrue(waitFor({ self.hasPendingReminder("Alpha", in: app) }, timeout: 5),
                      "Row value after Set: \(String(describing: BattyUITestHarness.sessionRow(named: "Alpha", in: app).value))")
    }

    /// Closing the Session cancels its Reminder: nothing is recorded when
    /// the clock passes the due time.
    @MainActor
    func testClosingTheSessionCancelsItsReminder() throws {
        let app = launch(script: [["intent": "createSession", "name": "Alpha"]])
        defer { app.terminate() }

        chooseFromRemindMe("In 5 Minutes", onRowNamed: "Alpha", in: app)
        XCTAssertTrue(waitFor({ self.hasPendingReminder("Alpha", in: app) }, timeout: 5))

        BattyUITestHarness.sessionRow(named: "Alpha", in: app).rightClick()
        // The menu bar's File > Close is also titled "Close" and closes the
        // window, quitting the app; take the item from the row's context menu.
        let close = rowContextMenu(in: app).menuItems["Close"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.click()
        XCTAssertTrue(waitFor({ !BattyUITestHarness.sessionRow(named: "Alpha", in: app).exists }, timeout: 5))

        advanceClock("five minutes", in: app)
        openBellFeed(in: app)
        XCTAssertEqual(reminderEntryIDs(in: app).count, 0, "A closed Session's Reminder must never fire")
    }
}
