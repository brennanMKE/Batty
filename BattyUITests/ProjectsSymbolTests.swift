// ProjectsSymbolTests.swift

import XCTest

/// The Sidebar row icon and the Project symbol picker (#0482). A row's icon is read
/// from the row's accessibility value, see `ProjectsUITestCase.rowIcon`.
nonisolated final class ProjectsSymbolTests: ProjectsUITestCase {
    private func seed(symbol: String?) throws -> [[String: Any]] {
        [ProjectFixture.project(
            name: "Board",
            root: try makeDirectory("board-root"),
            layout: ProjectFixture.terminal(),
            preset: "singlePane",
            symbol: symbol
        )]
    }

    @MainActor
    private func pickerDiagnostics(_ app: XCUIApplication) -> String {
        let ids = BattyScreen.identifiers(withPrefix: "project-editor.symbol", in: app).sorted()
        return "ids=\(ids) sheets=\(app.sheets.count) tree=\(app.sheets.firstMatch.debugDescription)"
    }

    @MainActor
    func testPlainRowIsACircleAndAProjectRowShowsItsSymbolAndFollowsAnEditorSave() throws {
        let (app, initial) = try launchApp(projects: try seed(symbol: "terminal"))
        defer { app.terminate() }
        let original = try XCTUnwrap(initial?.selectedSession)
        waitForRowIcon(original.name, "circle.fill", in: app)
        XCTAssertEqual(BattyUITestHarness.sessionRow(named: original.name, in: app).label, original.name, "the circle's label merged into the row label")

        openThroughPicker("Board", in: app)
        waitForRowIcon("Board", "terminal.fill", in: app)
        waitForRowIcon(original.name, "circle.fill", in: app)

        openEditorFromFileMenu(in: app)
        click("project-editor.list.row.Board", in: app)
        let button = element("project-editor.symbol", in: app)
        XCTAssertTrue(button.waitForExistence(timeout: 5), "no Symbol button in the editor")
        XCTAssertEqual(button.value as? String, "Terminal")
        dismissBanners(in: app)
        button.click()
        XCTAssertTrue(element("project-editor.symbol.chip", in: app).waitForExistence(timeout: 5), "the Symbol picker did not open \(pickerDiagnostics(app))")

        // Terminal is cell 1 of the Suggested symbols in a 9-wide grid; Chip is cell 18, two rows down in column 0.
        app.typeKey(XCUIKeyboardKey.leftArrow.rawValue, modifierFlags: [])
        for _ in 0..<2 { app.typeKey(XCUIKeyboardKey.downArrow.rawValue, modifierFlags: []) }
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
        XCTAssertTrue(waitFor({ !self.element("project-editor.symbol.chip", in: app).exists }, timeout: 5), "Return did not close the picker")
        XCTAssertTrue(waitFor({ (button.value as? String) == "Chip" }, timeout: 5), "the Symbol button reads \(String(describing: button.value))")

        waitForRowIcon("Board", "terminal.fill", in: app)
        click("project-editor.save", in: app)

        waitForRowIcon("Board", "cpu.fill", in: app)
        waitForRowIcon(original.name, "circle.fill", in: app)
        XCTAssertEqual(ProjectFixture.read(storeFile)?.first?["symbol"] as? String, "chip")
    }

    @MainActor
    func testEscapeClosesThePickerWithoutChangingTheSymbol() throws {
        let (app, _) = try launchApp(projects: try seed(symbol: "terminal"))
        defer { app.terminate() }

        openEditorFromFileMenu(in: app)
        click("project-editor.list.row.Board", in: app)
        let button = element("project-editor.symbol", in: app)
        dismissBanners(in: app)
        button.click()
        XCTAssertTrue(element("project-editor.symbol.chip", in: app).waitForExistence(timeout: 5))
        app.typeKey(XCUIKeyboardKey.downArrow.rawValue, modifierFlags: [])
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])

        XCTAssertTrue(waitFor({ !self.element("project-editor.symbol.chip", in: app).exists }, timeout: 5), "Escape did not close the picker")
        XCTAssertEqual(button.value as? String, "Terminal")
    }

    @MainActor
    func testReturnOnTheFocusedSymbolButtonOpensThePicker() throws {
        let (app, _) = try launchApp(projects: try seed(symbol: "terminal"))
        defer { app.terminate() }

        openEditorFromFileMenu(in: app)
        click("project-editor.list.row.Board", in: app)
        let button = element("project-editor.symbol", in: app)
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        dismissBanners(in: app)
        button.click()
        XCTAssertTrue(element("project-editor.symbol.chip", in: app).waitForExistence(timeout: 5))
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        XCTAssertTrue(waitFor({ !self.element("project-editor.symbol.chip", in: app).exists }, timeout: 5))

        // Escape returns focus to the button, so Return reopens the picker.
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
        XCTAssertTrue(element("project-editor.symbol.chip", in: app).waitForExistence(timeout: 5), "Return on the focused Symbol button did not open the picker")
    }

    @MainActor
    func testTypingAFullSymbolNameAndPressingReturnChoosesItAndSavesTheName() throws {
        let (app, _) = try launchApp(projects: try seed(symbol: "terminal"))
        defer { app.terminate() }

        openEditorFromFileMenu(in: app)
        click("project-editor.list.row.Board", in: app)
        let button = element("project-editor.symbol", in: app)
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        dismissBanners(in: app)
        button.click()
        XCTAssertTrue(element("project-editor.symbol.chip", in: app).waitForExistence(timeout: 5), "the Symbol picker did not open \(pickerDiagnostics(app))")

        app.typeText("flame.circle.fill\n")
        XCTAssertTrue(waitFor({ !self.element("project-editor.symbol.chip", in: app).exists }, timeout: 5), "Return did not close the picker")
        XCTAssertTrue(waitFor({ (button.value as? String) == "flame.circle.fill" }, timeout: 5), "the Symbol button reads \(String(describing: button.value))")

        click("project-editor.save", in: app)
        let stored = try XCTUnwrap(ProjectFixture.read(storeFile)?.first)
        XCTAssertEqual(stored["symbolName"] as? String, "flame.circle.fill")
        XCTAssertEqual(stored["symbol"] as? String, "folder")
    }

    @MainActor
    func testAProjectWithNoSymbolShowsTheFolder() throws {
        let (app, _) = try launchApp(projects: try seed(symbol: nil))
        defer { app.terminate() }

        openThroughPicker("Board", in: app)
        waitForRowIcon("Board", "folder.fill", in: app)
    }
}
