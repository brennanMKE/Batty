// SheetMenuGateTests.swift

import XCTest

/// Menu chords pressed while a sheet is attached to the content window
/// (#0641). `BattyShortcuts` declines every chord while the sheet is key, so
/// AppKit hands it to the main menu, whose Session, Pane and Tab items used to
/// act on the window behind the sheet.
///
/// "Nothing happened" is proven by ordering rather than by waiting: Escape
/// closes the sheet through the same event queue the chord travelled, so a
/// topology read after the sheet is gone sees the chord's effect, if any.
///
/// Runs only through `tools/run-ui-tests-vm.sh`, never on a host Mac.
nonisolated final class SheetMenuGateTests: ProjectsUITestCase {

    // MARK: - Helpers

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

    /// Escape closes the rename sheet; waits until its field is gone.
    @MainActor
    private func closeRenameSheet(_ field: XCUIElement, in app: XCUIApplication) {
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        XCTAssertTrue(waitFor({ !field.exists }, timeout: 5), "Escape must close the Rename Session sheet")
    }

    /// One Session, "Alpha", whose Terminal Pane has two Tabs at an idle prompt.
    @MainActor
    private func launchWithTwoTabs() throws -> (app: XCUIApplication, session: UUID, pane: UUID) {
        let (app, _) = try launchApp(script: [["intent": "createSession", "name": "Alpha"]])
        let initial = try XCTUnwrap(BattyCLI.waitForTopology { $0.selectedSession != nil })
        let session = try XCTUnwrap(initial.selectedSession)
        let pane = session.focusedPaneID
        app.typeKey("t", modifierFlags: [.command])
        let settled = BattyCLI.waitForTopology { $0.session(session.id)?.pane(pane)?.tabIDs.count == 2 }
        XCTAssertNotNil(settled, "the second Tab did not open")
        assertShellResponds(pane: pane, app: app)
        return (app, session.id, pane)
    }

    @MainActor
    private func tabCount(session: UUID, pane: UUID) throws -> Int {
        try XCTUnwrap(BattyCLI.topology()?.session(session)?.pane(pane)?.tabIDs.count)
    }

    @MainActor
    private func sessionCount() throws -> Int {
        try XCTUnwrap(BattyCLI.topology()?.sessions.count)
    }

    // MARK: - Chords

    @MainActor
    func testCommandWWhileRenameSheetIsUpDoesNotCloseTheTab() throws {
        let (app, session, pane) = try launchWithTwoTabs()
        defer { app.terminate() }
        let field = openRenameSheet(onRowNamed: "Alpha", in: app)

        app.typeKey("w", modifierFlags: [.command])
        XCTAssertTrue(hasKeyboardFocus(field), "the rename field must keep keyboard focus after Cmd-W")
        closeRenameSheet(field, in: app)
        XCTAssertEqual(try tabCount(session: session, pane: pane), 2, "Cmd-W over the Rename sheet closed a Tab behind it")

        app.typeKey("w", modifierFlags: [.command])
        XCTAssertNotNil(BattyCLI.waitForTopology { $0.session(session)?.pane(pane)?.tabIDs.count == 1 },
                        "Cmd-W did not close a Tab once the sheet was gone")
    }

    @MainActor
    func testCommandTWhileRenameSheetIsUpDoesNotAddATab() throws {
        let (app, session, pane) = try launchWithTwoTabs()
        defer { app.terminate() }
        let field = openRenameSheet(onRowNamed: "Alpha", in: app)

        app.typeKey("t", modifierFlags: [.command])
        XCTAssertTrue(hasKeyboardFocus(field), "the rename field must keep keyboard focus after Cmd-T")
        closeRenameSheet(field, in: app)
        XCTAssertEqual(try tabCount(session: session, pane: pane), 2, "Cmd-T over the Rename sheet added a Tab behind it")

        app.typeKey("t", modifierFlags: [.command])
        XCTAssertNotNil(BattyCLI.waitForTopology { $0.session(session)?.pane(pane)?.tabIDs.count == 3 },
                        "Cmd-T did not add a Tab once the sheet was gone")
    }

    @MainActor
    func testCommandNWhileRenameSheetIsUpDoesNotAddASession() throws {
        let (app, _, _) = try launchWithTwoTabs()
        defer { app.terminate() }
        let before = try sessionCount()
        let field = openRenameSheet(onRowNamed: "Alpha", in: app)

        app.typeKey("n", modifierFlags: [.command])
        XCTAssertTrue(hasKeyboardFocus(field), "the rename field must keep keyboard focus after Cmd-N")
        closeRenameSheet(field, in: app)
        XCTAssertEqual(try sessionCount(), before, "Cmd-N over the Rename sheet added a Session behind it")

        app.typeKey("n", modifierFlags: [.command])
        XCTAssertNotNil(BattyCLI.waitForTopology { $0.sessions.count == before + 1 },
                        "Cmd-N did not add a Session once the sheet was gone")
    }

    @MainActor
    func testPaneBackgroundImagesWhileRenameSheetIsUpDoesNotStackASheet() throws {
        let (app, _, _) = try launchWithTwoTabs()
        defer { app.terminate() }
        let field = openRenameSheet(onRowNamed: "Alpha", in: app)
        let sheetsBefore = app.sheets.count

        let menu = openMenu("Pane", in: app)
        let item = menuItem("Background Images", in: menu)
        XCTAssertTrue(item.waitForExistence(timeout: 5), "the Pane menu has no Background Images item: \(menuTitles(menu))")
        item.click()

        XCTAssertEqual(app.sheets.count, sheetsBefore, "Pane > Background Images... stacked a second sheet over the Rename sheet")
        XCTAssertTrue(hasKeyboardFocus(field), "the rename field must keep keyboard focus")
        closeRenameSheet(field, in: app)
        XCTAssertEqual(app.sheets.count, 0, "a sheet is still up after the Rename sheet closed")
    }

    // MARK: - Paste confirmation

    /// The confirmation sheet's Paste button sends while its own sheet is
    /// still attached, so the gate must not swallow it.
    @MainActor
    func testConfirmedMultiLinePasteReachesTheTerminal() throws {
        let (app, initial) = try launchApp(extraArguments: ["-co.sstools.Batty.pasteStrictness", "alwaysOnMultiline"])
        defer { app.terminate() }
        let pane = try XCTUnwrap(initial?.selectedSession?.focusedPaneID)
        assertShellResponds(pane: pane, app: app)

        let first = scratch.appending(path: "pasted-a-\(UUID().uuidString.prefix(8))")
        let second = scratch.appending(path: "pasted-b-\(UUID().uuidString.prefix(8))")
        let source = scratch.appending(path: "clip.txt")
        try "touch \(BattyCLI.shellQuoted(first.path))\ntouch \(BattyCLI.shellQuoted(second.path))\n"
            .write(to: source, atomically: true, encoding: .utf8)
        runInTerminal("pbcopy < \(BattyCLI.shellQuoted(source.path))", pane: pane, app: app)
        assertShellResponds(pane: pane, app: app)

        let terminal = BattyScreen.terminalPane(pane, in: app)
        terminal.click()
        app.typeKey("v", modifierFlags: [.command])
        let paste = app.sheets.buttons["Paste"].firstMatch
        XCTAssertTrue(paste.waitForExistence(timeout: 5), "the multi-line paste confirmation sheet did not appear")
        paste.click()
        XCTAssertTrue(paste.waitForNonExistence(timeout: 5), "the paste confirmation sheet did not close")

        // zsh enables bracketed paste, so the pasted lines (trailing newline
        // included) land in the line editor and run only on Return.
        terminal.click()
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])

        XCTAssertTrue(BattyUITestHarness.waitForFile(at: first.path, timeout: 30), "the confirmed paste's first line did not run")
        XCTAssertTrue(BattyUITestHarness.waitForFile(at: second.path, timeout: 30), "the confirmed paste's second line did not run")
    }
}
