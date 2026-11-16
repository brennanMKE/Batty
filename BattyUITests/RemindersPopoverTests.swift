// RemindersPopoverTests.swift

import XCTest

/// The Reminders toolbar button and popover (#0640). The app is launched
/// with `BATTY_UI_TEST_REMINDER_CLOCK=manual`, so time passes only through
/// the test-only Command Palette entries.
///
/// Runs only through `tools/run-ui-tests-vm.sh`, never on a host Mac.
nonisolated final class RemindersPopoverTests: XCTestCase {

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

    @MainActor
    private func rowContextMenu(in app: XCUIApplication) -> XCUIElementQuery {
        app.menus.containing(NSPredicate(format: "title == 'Reset Name'"))
    }

    @MainActor
    private func chooseFromContextMenu(_ item: String, onRowNamed title: String, in app: XCUIApplication) {
        let row = BattyUITestHarness.sessionRow(named: title, in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 5), "session-row.\(title) must exist")
        row.rightClick()
        let entry = rowContextMenu(in: app).menuItems[item].firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 5), "The row's context menu must offer \(item)")
        entry.click()
    }

    /// Sets a Reminder on `title` from its row: `digit` 1 is 5 minutes, 4 is 1 hour.
    @MainActor
    private func setReminder(on title: String, text: String, digit: String, in app: XCUIApplication) {
        chooseFromContextMenu("Remind Me\u{2026}", onRowNamed: title, in: app)
        XCTAssertTrue(bar(in: app).waitForExistence(timeout: 5), "Remind Me… must open the Quick Reminder bar")
        app.typeText(text)
        app.typeKey(digit, modifierFlags: .command)
        XCTAssertTrue(waitFor({ !self.bar(in: app).exists }, timeout: 5), "⌘\(digit) must commit and close the bar")
        XCTAssertTrue(waitFor({ self.reminderState(title, in: app)?.hasPrefix("reminder pending") == true }, timeout: 5),
                      "\(title) must have a pending Reminder")
    }

    @MainActor
    private func reminderState(_ title: String, in app: XCUIApplication) -> String? {
        let value = BattyUITestHarness.sessionRow(named: title, in: app).value as? String
        guard let range = value?.range(of: "reminder ") else { return nil }
        return String(value![range.lowerBound...])
    }

    @MainActor
    private func selectRow(_ title: String, in app: XCUIApplication) {
        BattyUITestHarness.sessionRow(named: title, in: app).click()
        XCTAssertTrue(waitFor({ (BattyUITestHarness.sessionRow(named: title, in: app).value as? String)?.hasPrefix("selected") == true }, timeout: 5),
                      "\(title) must be selected")
    }

    @MainActor
    private func isSelected(_ title: String, in app: XCUIApplication) -> Bool {
        (BattyUITestHarness.sessionRow(named: title, in: app).value as? String)?.hasPrefix("selected") == true
    }

    @MainActor
    private func advanceClock(_ phrase: String, in app: XCUIApplication) {
        app.typeKey("p", modifierFlags: [.command, .shift])
        let palette = element("command-palette.root", in: app)
        XCTAssertTrue(palette.waitForExistence(timeout: 5))
        palette.typeText("UI Test: Advance Reminder Clock by \(phrase)")
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
        XCTAssertTrue(waitFor({ !palette.exists }, timeout: 5), "The palette must close after running the entry")
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

    @MainActor
    private func hasKeyboardFocus(_ element: XCUIElement) -> Bool {
        element.exists && (element.value(forKey: "hasKeyboardFocus") as? Bool) == true
    }

    @MainActor
    private func openRenameSheet(onRowNamed title: String, in app: XCUIApplication) -> XCUIElement {
        chooseFromContextMenu("Rename", onRowNamed: title, in: app)
        let field = element("rename-session.field", in: app)
        XCTAssertTrue(field.waitForExistence(timeout: 5), "the Rename Session sheet must open")
        XCTAssertTrue(waitFor({ self.hasKeyboardFocus(field) }, timeout: 5), "the rename field must hold keyboard focus")
        return field
    }

    @MainActor
    private func remindersButton(in app: XCUIApplication) -> XCUIElement {
        element("toolbar.reminders", in: app)
    }

    @MainActor
    private func remindersValue(in app: XCUIApplication) -> String? {
        remindersButton(in: app).value as? String
    }

    @MainActor
    private func popoverIsOpen(in app: XCUIApplication) -> Bool {
        element("reminders.list", in: app).exists || element("reminders.empty", in: app).exists
    }

    @MainActor
    private func openReminders(in app: XCUIApplication) {
        let button = remindersButton(in: app)
        XCTAssertTrue(button.waitForExistence(timeout: 5), "toolbar.reminders must exist")
        button.click()
        XCTAssertTrue(waitFor({ self.popoverIsOpen(in: app) }, timeout: 5), "The Reminders popover must open")
    }

    @MainActor
    private func closeReminders(in app: XCUIApplication) {
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        XCTAssertTrue(waitFor({ !self.popoverIsOpen(in: app) }, timeout: 5), "Escape must close the Reminders popover")
    }

    @MainActor
    private func dueValue(_ title: String, in app: XCUIApplication) -> String? {
        element("reminders-due.\(title)", in: app).value as? String
    }

    // MARK: - Tests

    @MainActor
    func testRemindersButtonOpensThePopoverWithUpcoming() throws {
        let app = launch(script: [["intent": "createSession", "name": "Alpha"]])
        defer { app.terminate() }
        XCTAssertEqual(remindersValue(in: app), "none")

        setReminder(on: "Alpha", text: "check CI", digit: "1", in: app)
        XCTAssertTrue(waitFor({ self.remindersValue(in: app) == "1 upcoming" }, timeout: 5),
                      "button value: \(String(describing: remindersValue(in: app)))")

        openReminders(in: app)
        let row = element("reminders-upcoming.Alpha", in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 5), "Alpha must be listed under Upcoming")
        XCTAssertTrue((row.value as? String)?.hasPrefix("reminder pending: Reminder at") == true,
                      "row value: \(String(describing: row.value))")
        let dueRows = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'reminders-due.'"))
        XCTAssertEqual(dueRows.count, 0, "Nothing has fired yet")
    }

    @MainActor
    func testOptionCommandRTogglesTheRemindersPopover() throws {
        let app = launch(script: [["intent": "createSession", "name": "Alpha"]])
        defer { app.terminate() }

        app.typeKey("r", modifierFlags: [.command, .option])
        XCTAssertTrue(waitFor({ self.popoverIsOpen(in: app) }, timeout: 5), "⌥⌘R must open the popover")
        app.typeKey("r", modifierFlags: [.command, .option])
        XCTAssertTrue(waitFor({ !self.popoverIsOpen(in: app) }, timeout: 5), "⌥⌘R must close the open popover")
        app.typeKey("r", modifierFlags: [.command, .option])
        XCTAssertTrue(waitFor({ self.popoverIsOpen(in: app) }, timeout: 5), "⌥⌘R must reopen the popover")
        closeReminders(in: app)
    }

    @MainActor
    func testOptionCommandRWhileAnotherSheetIsUpDoesNotOpenThePopover() throws {
        let app = launch(script: [["intent": "createSession", "name": "Alpha"]])
        defer { app.terminate() }
        let field = openRenameSheet(onRowNamed: "Alpha", in: app)

        app.typeKey("r", modifierFlags: [.command, .option])
        XCTAssertFalse(waitFor({ self.popoverIsOpen(in: app) }, timeout: 2), "⌥⌘R must not open the popover over a sheet")
        XCTAssertTrue(hasKeyboardFocus(field), "the rename field must keep keyboard focus")
    }

    @MainActor
    func testFiredReminderShowsUnreadInDueAndRingsTheButton() throws {
        let app = launch(script: [
            ["intent": "createSession", "name": "Alpha"],
            ["intent": "createSession", "name": "Beta"],
        ])
        defer { app.terminate() }
        setReminder(on: "Alpha", text: "back to Alpha", digit: "1", in: app)
        selectRow("Beta", in: app)

        advanceClock("five minutes", in: app)

        XCTAssertTrue(waitFor({ self.remindersValue(in: app)?.contains("unread") == true }, timeout: 5),
                      "button value: \(String(describing: remindersValue(in: app)))")
        openReminders(in: app)
        XCTAssertTrue(waitFor({ self.dueValue("Alpha", in: app) == "reminder due, unread" }, timeout: 5),
                      "due row value: \(String(describing: dueValue("Alpha", in: app)))")
        closeReminders(in: app)
        openReminders(in: app)
        XCTAssertEqual(dueValue("Alpha", in: app), "reminder due, unread", "Opening the popover must mark nothing read")
        closeReminders(in: app)

        app.typeKey("b", modifierFlags: [.command, .shift])
        XCTAssertTrue(app.staticTexts["No bell events"].firstMatch.waitForExistence(timeout: 5),
                      "A fired Reminder must leave the Bell Feed empty")
        XCTAssertEqual(element("toolbar.bell-feed", in: app).label, "Bell Feed")
    }

    @MainActor
    func testOpenSessionFromADueRowRemovesItAndKeepsTheFocusedPane() throws {
        let app = launch(script: [
            ["intent": "createSession", "name": "Alpha"],
            ["intent": "splitHorizontal"],
            ["intent": "createSession", "name": "Beta"],
        ])
        defer { app.terminate() }

        selectRow("Alpha", in: app)
        XCTAssertTrue(waitFor({ self.focusedPaneIndex(in: app) == 1 }, timeout: 5),
                      "Setup: Alpha's second Pane must be focused")
        selectRow("Beta", in: app)
        setReminder(on: "Alpha", text: "back to Alpha", digit: "1", in: app)
        advanceClock("five minutes", in: app)

        openReminders(in: app)
        let row = element("reminders-due.Alpha", in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 5), "Alpha must be listed under Due")
        row.click()
        XCTAssertTrue(waitFor({ !self.popoverIsOpen(in: app) }, timeout: 5), "Open Session must close the popover")
        XCTAssertTrue(waitFor({ self.isSelected("Alpha", in: app) }, timeout: 5), "Open Session must select Alpha")
        XCTAssertEqual(focusedPaneIndex(in: app), 1, "Open Session must leave Alpha's focused Pane where it was")

        openReminders(in: app)
        XCTAssertTrue(element("reminders.empty", in: app).waitForExistence(timeout: 5), "The visit must remove the Due row")
        XCTAssertEqual(remindersValue(in: app), "none")
    }

    @MainActor
    func testMarkAllReadThenClearReadEmptiesDueButKeepsUpcoming() throws {
        let app = launch(script: [
            ["intent": "createSession", "name": "Alpha"],
            ["intent": "createSession", "name": "Beta"],
            ["intent": "createSession", "name": "Gamma"],
        ])
        defer { app.terminate() }
        setReminder(on: "Alpha", text: "a", digit: "1", in: app)
        setReminder(on: "Beta", text: "b", digit: "4", in: app)
        selectRow("Gamma", in: app)
        advanceClock("five minutes", in: app)

        openReminders(in: app)
        let markAll = element("reminders.mark-all-read", in: app)
        XCTAssertTrue(markAll.waitForExistence(timeout: 5), "Mark All Read must show while a Due row is unread")
        markAll.click()
        XCTAssertTrue(waitFor({ self.dueValue("Alpha", in: app) == "reminder due, read" }, timeout: 5),
                      "due row value: \(String(describing: dueValue("Alpha", in: app)))")
        XCTAssertTrue(waitFor({ !markAll.exists }, timeout: 5), "Mark All Read must hide once nothing is unread")
        let clearRead = element("reminders.clear-read", in: app)
        XCTAssertTrue(clearRead.exists, "Clear Read must show while a Due row is read")
        XCTAssertFalse(remindersValue(in: app)?.contains("unread") == true)

        clearRead.click()
        XCTAssertTrue(waitFor({ !self.element("reminders-due.Alpha", in: app).exists }, timeout: 5),
                      "Clear Read must remove the read Due row")
        XCTAssertTrue(element("reminders-upcoming.Beta", in: app).exists, "Clear Read must keep Upcoming")
    }

    @MainActor
    func testRemindAgainFromTheRowMovesItToUpcoming() throws {
        let app = launch(script: [
            ["intent": "createSession", "name": "Alpha"],
            ["intent": "createSession", "name": "Beta"],
        ])
        defer { app.terminate() }
        setReminder(on: "Alpha", text: "again", digit: "1", in: app)
        selectRow("Beta", in: app)
        advanceClock("five minutes", in: app)

        openReminders(in: app)
        let again = element("reminders-due.again15.Alpha", in: app)
        XCTAssertTrue(again.waitForExistence(timeout: 5), "The selected Due row must show Remind Again")
        again.click()
        XCTAssertTrue(waitFor({ !self.element("reminders-due.Alpha", in: app).exists }, timeout: 5),
                      "Remind Again must remove the Due row")
        XCTAssertTrue(element("reminders-upcoming.Alpha", in: app).waitForExistence(timeout: 5),
                      "Remind Again must list the new Reminder under Upcoming")
    }

    @MainActor
    func testEditFromAnUpcomingRowOpensTheBarInEditMode() throws {
        let app = launch(script: [
            ["intent": "createSession", "name": "Alpha"],
            ["intent": "createSession", "name": "Beta"],
        ])
        defer { app.terminate() }
        setReminder(on: "Alpha", text: "check CI", digit: "1", in: app)
        selectRow("Beta", in: app)

        openReminders(in: app)
        let row = element("reminders-upcoming.Alpha", in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.hover()
        let edit = element("reminders-upcoming.edit.Alpha", in: app)
        XCTAssertTrue(edit.waitForExistence(timeout: 5), "Hovering an Upcoming row must show Edit")
        edit.click()

        XCTAssertTrue(waitFor({ !self.popoverIsOpen(in: app) }, timeout: 5), "Edit must close the popover")
        XCTAssertTrue(bar(in: app).waitForExistence(timeout: 5), "Edit must open the Quick Reminder bar")
        XCTAssertEqual(barText(in: app).value as? String, "check CI", "Edit mode must prefill the text")
        XCTAssertTrue(barRow("keep", in: app).exists, "Edit mode must offer Keep")
        XCTAssertTrue(waitFor({ self.hasKeyboardFocus(self.barText(in: app)) }, timeout: 5), "The bar's field must take focus")
        XCTAssertTrue(isSelected("Beta", in: app), "Edit must not change the selected Session")
    }

    @MainActor
    func testCancelFromAnUpcomingRowRemovesIt() throws {
        let app = launch(script: [["intent": "createSession", "name": "Alpha"]])
        defer { app.terminate() }
        setReminder(on: "Alpha", text: "cancel me", digit: "1", in: app)

        openReminders(in: app)
        let row = element("reminders-upcoming.Alpha", in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.hover()
        let cancel = element("reminders-upcoming.cancel.Alpha", in: app)
        XCTAssertTrue(cancel.waitForExistence(timeout: 5), "Hovering an Upcoming row must show Cancel")
        cancel.click()
        XCTAssertTrue(waitFor({ !row.exists }, timeout: 5), "Cancel must remove the row")
        XCTAssertTrue(element("reminders.empty", in: app).waitForExistence(timeout: 5))
        XCTAssertNil(reminderState("Alpha", in: app), "Cancel must remove the pending Reminder")
    }

    @MainActor
    func testNewReminderFromTheHeaderOpensTheBar() throws {
        let app = launch(script: [["intent": "createSession", "name": "Alpha"]])
        defer { app.terminate() }
        selectRow("Alpha", in: app)

        openReminders(in: app)
        element("reminders.new", in: app).click()
        XCTAssertTrue(waitFor({ !self.popoverIsOpen(in: app) }, timeout: 5), "New Reminder… must close the popover")
        XCTAssertTrue(bar(in: app).waitForExistence(timeout: 5), "New Reminder… must open the Quick Reminder bar")
        XCTAssertTrue(waitFor({ self.hasKeyboardFocus(self.barText(in: app)) }, timeout: 5), "The bar's field must take focus")
    }

    @MainActor
    func testEmptyStateOffersNewReminder() throws {
        let app = launch(script: [["intent": "createSession", "name": "Alpha"]])
        defer { app.terminate() }

        openReminders(in: app)
        XCTAssertTrue(element("reminders.empty", in: app).exists, "No Reminders must show the empty state")
        let new = element("reminders.empty.new", in: app)
        XCTAssertTrue(new.waitForExistence(timeout: 5), "The empty state must offer New Reminder")
        new.click()
        XCTAssertTrue(bar(in: app).waitForExistence(timeout: 5), "The empty state's button must open the bar")
        XCTAssertTrue(waitFor({ self.hasKeyboardFocus(self.barText(in: app)) }, timeout: 5), "The bar's field must take focus")
    }

    /// The popover opens with focus on New Reminder…, not the List; the keys must still act.
    @MainActor
    func testKeysRemindAgainEditAndCancelFromTheList() throws {
        let app = launch(script: [
            ["intent": "createSession", "name": "Alpha"],
            ["intent": "createSession", "name": "Beta"],
            ["intent": "createSession", "name": "Gamma"],
        ])
        defer { app.terminate() }
        setReminder(on: "Alpha", text: "fire", digit: "1", in: app)
        setReminder(on: "Beta", text: "later", digit: "4", in: app)
        selectRow("Gamma", in: app)
        advanceClock("five minutes", in: app)

        openReminders(in: app)
        XCTAssertTrue(element("reminders-due.Alpha", in: app).waitForExistence(timeout: 5))
        app.typeKey("r", modifierFlags: [])
        XCTAssertTrue(waitFor({ !self.element("reminders-due.Alpha", in: app).exists }, timeout: 5),
                      "R must remind again on the selected Due row")
        XCTAssertTrue(element("reminders-upcoming.Alpha", in: app).waitForExistence(timeout: 5))

        // Upcoming is now Alpha (15 min) then Beta (1 hour); the selection
        // moved to the row that took the Due row's place.
        app.typeKey(XCUIKeyboardKey.downArrow.rawValue, modifierFlags: [])
        app.typeKey("e", modifierFlags: [])
        XCTAssertTrue(bar(in: app).waitForExistence(timeout: 5), "E must open the bar on the selected Upcoming row")
        XCTAssertEqual(barText(in: app).value as? String, "later", "E must edit Beta's Reminder")
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        XCTAssertTrue(waitFor({ !self.bar(in: app).exists }, timeout: 5))

        openReminders(in: app)
        app.typeKey(XCUIKeyboardKey.downArrow.rawValue, modifierFlags: [])
        app.typeKey(XCUIKeyboardKey.delete.rawValue, modifierFlags: [])
        XCTAssertTrue(waitFor({ !self.element("reminders-upcoming.Beta", in: app).exists }, timeout: 5),
                      "Delete must cancel the selected Upcoming row")
        XCTAssertTrue(element("reminders-upcoming.Alpha", in: app).exists)
    }
}
