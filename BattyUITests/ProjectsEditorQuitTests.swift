// ProjectsEditorQuitTests.swift

import XCTest

/// Quitting and closing with unsaved Project Editor edits (#0481). UI-test
/// mode normally skips the editor's quit question so XCUITest's teardown
/// `terminate()` cannot hang on it; the quit test turns it back on with
/// `BATTY_UI_TEST_PROMPT_EDITOR_ON_QUIT=1` and ends by answering Discard, so
/// the app quits on its own and teardown has nothing to hang on.
nonisolated final class ProjectsEditorQuitTests: ProjectsUITestCase {
    private func existingProject() throws -> [String: Any] {
        ProjectFixture.project(
            name: "Existing",
            root: try makeDirectory("existing-root"),
            layout: ProjectFixture.split("horizontal", [ProjectFixture.terminal(), ProjectFixture.terminal()]),
            preset: "horizontalSplit"
        )
    }

    @MainActor
    private func editExistingName(in app: XCUIApplication) {
        openEditorFromFileMenu(in: app)
        click("project-editor.list.row.Existing", in: app)
        replaceText(in: "project-editor.name", with: "Existing Changed", app: app)
    }

    @MainActor
    private func editorSheet(in app: XCUIApplication) -> XCUIElement {
        editorWindow(in: app).sheets.firstMatch
    }

    @MainActor
    func testQuitWithUnsavedEditsAsksAndCancelKeepsTheAppAndTheEdit() throws {
        let (app, _) = try launchApp(
            projects: [try existingProject()],
            extraEnvironment: ["BATTY_UI_TEST_PROMPT_EDITOR_ON_QUIT": "1"]
        )
        defer { app.terminate() }

        editExistingName(in: app)
        app.typeKey("q", modifierFlags: .command)

        let sheet = editorSheet(in: app)
        XCTAssertTrue(sheet.waitForExistence(timeout: 10), "Cmd-Q with unsaved edits did not ask")
        XCTAssertTrue(sheet.buttons["Save"].exists, "no Save button")
        XCTAssertTrue(sheet.buttons["Discard Changes"].exists, "no Discard Changes button")
        XCTAssertTrue(sheet.buttons["Cancel"].exists, "no Cancel button")

        sheet.buttons["Cancel"].click()
        XCTAssertTrue(waitFor({ !self.editorSheet(in: app).exists }, timeout: 10), "Cancel did not dismiss the question")
        XCTAssertEqual(app.state, .runningForeground, "Cancel did not cancel the quit")
        XCTAssertEqual(element("project-editor.name", in: app).value as? String, "Existing Changed", "Cancel lost the edit")
        XCTAssertEqual(ProjectFixture.names(in: storeFile), ["Existing"], "Cancel wrote the edit to the store")

        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(editorSheet(in: app).waitForExistence(timeout: 10), "the second Cmd-Q did not ask")
        editorSheet(in: app).buttons["Discard Changes"].click()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 20), "Discard did not let the quit continue")
        XCTAssertEqual(ProjectFixture.names(in: storeFile), ["Existing"], "Discard wrote the edit to the store")
    }

    @MainActor
    func testClosingTheLastContentWindowKeepsTheAppWhileTheEditorHasUnsavedEditsAndCmdWClosesTheEditor() throws {
        let (app, _) = try launchApp(projects: [try existingProject()])
        defer { app.terminate() }

        let contentIdentifier = app.windows.firstMatch.identifier
        editExistingName(in: app)
        let content = app.windows.matching(NSPredicate(format: "identifier == %@", contentIdentifier)).firstMatch
        XCTAssertTrue(content.exists, "no content window")
        let windowMenu = openMenu("Window", in: app)
        let contentItem = menuItem("Session 1", in: windowMenu)
        XCTAssertTrue(contentItem.waitForExistence(timeout: 5), "the Window menu does not list the content window: \(menuTitles(windowMenu))")
        contentItem.click()
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(waitFor({ !content.exists }, timeout: 10), "the content window did not close")

        XCTAssertEqual(app.state, .runningForeground, "the app quit with unsaved editor edits")
        XCTAssertTrue(editorWindow(in: app).exists, "the editor went away with the content window")
        XCTAssertNotNil(BattyCLI.topology(), "the app stopped answering")

        let menu = openMenu("Tab", in: app)
        let close = menuItem("Close", in: menu)
        XCTAssertTrue(close.waitForExistence(timeout: 5), "no Close item in the Tab menu: \(menuTitles(menu))")
        XCTAssertTrue(close.isEnabled, "Close is disabled with only the editor open")
        closeMenus(app)

        app.typeKey("w", modifierFlags: .command)
        let sheet = editorSheet(in: app)
        XCTAssertTrue(sheet.waitForExistence(timeout: 10), "Cmd-W with unsaved edits did not ask")
        sheet.buttons["Discard Changes"].click()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 20), "closing the editor did not finish the held quit")
        XCTAssertEqual(ProjectFixture.names(in: storeFile), ["Existing"], "Discard wrote the edit to the store")
    }

    @MainActor
    func testCmdWWithASheetOverTheEditorLeavesTheSheetAndTheEditorAlone() throws {
        let (app, _) = try launchApp(projects: [try existingProject()])
        defer { app.terminate() }

        editExistingName(in: app)
        click("project-editor.new-project", in: app)
        let sheet = editorSheet(in: app)
        XCTAssertTrue(sheet.waitForExistence(timeout: 10), "New Project with unsaved edits did not ask")

        app.typeKey("w", modifierFlags: .command)
        sheet.buttons["Cancel"].click()
        XCTAssertTrue(waitFor({ !self.editorSheet(in: app).exists }, timeout: 10), "Cancel did not dismiss the question")
        XCTAssertTrue(editorWindow(in: app).exists, "Cmd-W behind the sheet closed the editor")
        XCTAssertEqual(element("project-editor.name", in: app).value as? String, "Existing Changed", "the edit was lost")
    }

    @MainActor
    func testCmdWAndCmdQWhileTheRootFolderPanelIsUpLeaveThePanelEditorAndAppAlone() throws {
        let (app, _) = try launchApp(
            projects: [try existingProject()],
            extraEnvironment: ["BATTY_UI_TEST_PROMPT_EDITOR_ON_QUIT": "1"]
        )
        defer { app.terminate() }

        editExistingName(in: app)
        click("project-editor.root.choose", in: app)
        let panel = editorSheet(in: app)
        XCTAssertTrue(panel.waitForExistence(timeout: 10), "Choose... did not present the folder panel as a sheet on the editor")

        app.typeKey("w", modifierFlags: .command)
        app.typeKey("q", modifierFlags: .command)

        XCTAssertEqual(app.state, .runningForeground, "Cmd-Q with the folder panel up quit the app")
        XCTAssertTrue(editorWindow(in: app).exists, "Cmd-W with the folder panel up closed the editor")
        XCTAssertTrue(panel.exists, "Cmd-W or Cmd-Q dismissed the folder panel")
        XCTAssertNotNil(BattyCLI.topology(), "the app stopped answering")

        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitFor({ !self.editorSheet(in: app).exists }, timeout: 10), "Escape did not dismiss the folder panel")
        XCTAssertEqual(element("project-editor.name", in: app).value as? String, "Existing Changed", "the edit was lost")
        XCTAssertEqual(ProjectFixture.names(in: storeFile), ["Existing"], "the edit was written to the store")
    }
}
