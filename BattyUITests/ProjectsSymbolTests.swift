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
    private func popoverDiagnostics(_ app: XCUIApplication) -> String {
        let ids = BattyScreen.identifiers(withPrefix: "project-editor.symbol", in: app).sorted()
        return "ids=\(ids) popovers=\(app.popovers.count) tree=\(app.popovers.firstMatch.debugDescription)"
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
        dismissBanners()
        button.click()
        XCTAssertTrue(element("project-editor.symbol.chip", in: app).waitForExistence(timeout: 5), "the Symbol popover did not open \(popoverDiagnostics(app))")

        // Terminal is cell 1 of 36 in a 6-wide grid; Chip is cell 18, three rows down in column 0.
        app.typeKey(XCUIKeyboardKey.leftArrow.rawValue, modifierFlags: [])
        for _ in 0..<3 { app.typeKey(XCUIKeyboardKey.downArrow.rawValue, modifierFlags: []) }
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
        XCTAssertTrue(waitFor({ !self.element("project-editor.symbol.chip", in: app).exists }, timeout: 5), "Return did not close the popover")
        XCTAssertTrue(waitFor({ (button.value as? String) == "Chip" }, timeout: 5), "the Symbol button reads \(String(describing: button.value))")

        waitForRowIcon("Board", "terminal.fill", in: app)
        click("project-editor.save", in: app)

        waitForRowIcon("Board", "cpu.fill", in: app)
        waitForRowIcon(original.name, "circle.fill", in: app)
        XCTAssertEqual(ProjectFixture.read(storeFile)?.first?["symbol"] as? String, "chip")
    }

    @MainActor
    func testEscapeClosesThePopoverWithoutChangingTheSymbol() throws {
        let (app, _) = try launchApp(projects: try seed(symbol: "terminal"))
        defer { app.terminate() }

        openEditorFromFileMenu(in: app)
        click("project-editor.list.row.Board", in: app)
        let button = element("project-editor.symbol", in: app)
        dismissBanners()
        button.click()
        XCTAssertTrue(element("project-editor.symbol.chip", in: app).waitForExistence(timeout: 5))
        app.typeKey(XCUIKeyboardKey.downArrow.rawValue, modifierFlags: [])
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])

        XCTAssertTrue(waitFor({ !self.element("project-editor.symbol.chip", in: app).exists }, timeout: 5), "Escape did not close the popover")
        XCTAssertEqual(button.value as? String, "Terminal")
    }

    @MainActor
    func testReturnOnTheFocusedSymbolButtonOpensThePopover() throws {
        let (app, _) = try launchApp(projects: try seed(symbol: "terminal"))
        defer { app.terminate() }

        openEditorFromFileMenu(in: app)
        click("project-editor.list.row.Board", in: app)
        let button = element("project-editor.symbol", in: app)
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        dismissBanners()
        button.click()
        XCTAssertTrue(element("project-editor.symbol.chip", in: app).waitForExistence(timeout: 5))
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        XCTAssertTrue(waitFor({ !self.element("project-editor.symbol.chip", in: app).exists }, timeout: 5))

        // Escape returns focus to the button, so Return reopens the popover.
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
        XCTAssertTrue(element("project-editor.symbol.chip", in: app).waitForExistence(timeout: 5), "Return on the focused Symbol button did not open the popover")
    }

    @MainActor
    func testAProjectWithNoSymbolShowsTheFolder() throws {
        let (app, _) = try launchApp(projects: try seed(symbol: nil))
        defer { app.terminate() }

        openThroughPicker("Board", in: app)
        waitForRowIcon("Board", "folder.fill", in: app)
    }

    @MainActor
    func testFlagOffRowKeepsTheThreeColumnSymbol() throws {
        let (app, _) = try launchApp(flagOff: true, connectCLI: false)
        defer { app.terminate() }

        waitForRowIcon("Session 1", "rectangle.split.3x1", in: app)
    }
}
