// ProjectsFlagOffTests.swift

import XCTest

/// With the Projects flag forced off (`BATTY_UI_TEST_FORCE_PROJECTS_OFF=1`
/// beside the UI-test script, #0470) Projects must be invisible and inert
/// (#0478). The CLI half of inertness is compile-time in Prod and covered by
/// #0477's unit tests; the VM runs the Beta build, so it is not asserted here.
nonisolated final class ProjectsFlagOffTests: ProjectsUITestCase {
    private func seedProject() throws -> [String: Any] {
        ProjectFixture.project(
            name: "Ghost", root: try makeDirectory("ghost-root"), layout: ProjectFixture.terminal(), preset: "singlePane",
            isShared: true, modifiedAt: "2026-01-01T12:00:00Z")
    }

    @MainActor
    func testFlagOffRemovesEveryProjectsEntryPointAndWritesNothing() throws {
        let seeded = try seedProject()
        try ProjectFixture.write([seeded], to: storeFile)
        let seededBytes = try Data(contentsOf: storeFile)
        let storeDirectory = storeFile.deletingLastPathComponent()
        let (app, _) = try launchApp(projects: nil, flagOff: true, connectCLI: false)
        defer { app.terminate() }

        // Sidebar footer: the + button is there, the Open Project button is not.
        XCTAssertTrue(element("session-sidebar.add-session-button", in: app).waitForExistence(timeout: 10), "the Sidebar footer has no + button")
        XCTAssertFalse(element("session-sidebar.open-project-button", in: app).exists, "the Sidebar footer has an Open Project button with the flag off")

        // File menu: ordinary items are there, no Projects item is.
        let file = openMenu("File", in: app)
        XCTAssertTrue(menuItem("New Session", in: file).waitForExistence(timeout: 5), "the File menu did not populate: \(menuTitles(file))")
        for prefix in ["Open Project", "Choose Project", "New Project", "Save Session as", "Edit Projects", "Update"] {
            XCTAssertEqual(menuItemCount(startingWith: prefix, in: file), 0, "File has a \(prefix) item with the flag off: \(menuTitles(file))")
        }
        closeMenus(app)

        // Window menu: no Project Editor entry. Only meaningful while the editor is open,
        // which it cannot be with the flag off; the flag-on side (the entry present while
        // open) is ProjectsEditorTests.testEditProjectsMenuOpensTheEditorOnTheStoredProjects.
        let window = openMenu("Window", in: app)
        XCTAssertTrue(menuItem("Minimize", in: window).waitForExistence(timeout: 5), "the Window menu did not populate")
        XCTAssertEqual(window.menuItems.matching(NSPredicate(format: "title == %@", "Projects")).count, 0, "Window lists a Project Editor: \(menuTitles(window))")
        closeMenus(app)

        // Sidebar context menu: ordinary items are there, Save as Project is not.
        let row = BattyUITestHarness.sessionRow(named: "Session 1", in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.rightClick()
        let mute = app.menuItems.matching(NSPredicate(format: "title ENDSWITH %@", "Notifications")).firstMatch
        XCTAssertTrue(mute.waitForExistence(timeout: 5), "the Sidebar context menu did not open")
        for prefix in ["Save as Project", "Save as New Project", "Update"] {
            XCTAssertEqual(menuItemCount(startingWith: prefix, in: app), 0, "the Sidebar menu has a \(prefix) item with the flag off")
        }
        closeMenus(app)

        // Command Palette: a control query finds its row, then no Projects row exists.
        _ = openCommandPalette(in: app)
        app.typeText("About Batty")
        XCTAssertTrue(app.staticTexts["About Batty"].waitForExistence(timeout: 5), "the palette did not filter to its control row")
        app.typeKey("a", modifierFlags: .command)
        app.typeText("Project")
        XCTAssertTrue(waitFor({ !app.staticTexts["About Batty"].exists }, timeout: 5), "the palette did not re-filter")
        let projectRows = paletteRows(containing: "Project", in: app)
        XCTAssertEqual(projectRows.count, 0, "the palette lists Projects rows with the flag off: \(projectRows.allElementsBoundByIndex.map { $0.label + "|" + String(describing: $0.value) })")
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])

        // Open Quickly: it opens, and lists no Project row or hint.
        presentOpenQuickly(in: app)
        XCTAssertTrue(element("open-quickly.row", in: app).waitForExistence(timeout: 5), "Open Quickly lists no Tab row")
        XCTAssertFalse(element("open-quickly.tab-hint", in: app).exists, "Open Quickly shows a Tab-row hint with the flag off")
        app.typeText("Ghost")
        XCTAssertTrue(waitFor({ BattyScreen.identifiers(withPrefix: "open-quickly.row.project.", in: app).isEmpty }, timeout: 5), "Open Quickly lists a Project row with the flag off")
        XCTAssertFalse(element("open-quickly.hint", in: app).exists, "Open Quickly shows a Project hint with the flag off")
        XCTAssertFalse(element("open-quickly.tab-hint", in: app).exists, "Open Quickly shows a Tab-row hint with the flag off")
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])

        // Use the app further (add and select a Session) before checking the store is untouched.
        click("session-sidebar.add-session-button", in: app)
        let first = BattyUITestHarness.sessionRow(named: "Session 1", in: app)
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        first.click()

        // Inert: the configured store was never opened, written or backed up.
        XCTAssertEqual(try Data(contentsOf: storeFile), seededBytes, "the flag-off app rewrote projects.json")
        XCTAssertFalse(String(decoding: try Data(contentsOf: storeFile), as: UTF8.self).contains("lastOpenedAt"), "the flag-off app recorded an open")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: storeDirectory.path).sorted(), ["projects.json"], "the flag-off app wrote beside projects.json")
        XCTAssertFalse(editorWindow(in: app).exists)
    }

    @MainActor
    func testFlagOffNeverCreatesProjectsJson() throws {
        let (app, _) = try launchApp(projects: nil, flagOff: true, connectCLI: false)
        defer { app.terminate() }

        // Use the app: open and close the menus a Projects store would be built from.
        let file = openMenu("File", in: app)
        XCTAssertTrue(menuItem("New Session", in: file).waitForExistence(timeout: 5))
        closeMenus(app)
        _ = openCommandPalette(in: app)
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        app.terminate()

        XCTAssertFalse(FileManager.default.fileExists(atPath: storeFile.path), "projects.json exists after a flag-off run")
        XCTAssertFalse(FileManager.default.fileExists(atPath: storeFile.deletingLastPathComponent().path + "/projects.json.bak"))
    }

    /// Control for the two tests above: the same launch with the flag on does
    /// show the entry points, so their absence is the flag and not a menu that
    /// failed to populate.
    @MainActor
    func testFlagOnControlShowsTheEntryPoints() throws {
        let (app, _) = try launchApp(projects: [try seedProject()], connectCLI: false)
        defer { app.terminate() }

        XCTAssertTrue(element("session-sidebar.add-session-button", in: app).waitForExistence(timeout: 10), "the Sidebar footer has no + button")
        XCTAssertTrue(element("session-sidebar.open-project-button", in: app).exists, "the Sidebar footer has no Open Project button with the flag on")

        let file = openMenu("File", in: app)
        XCTAssertTrue(menuItem("Edit Projects", in: file).waitForExistence(timeout: 5), "File has no Edit Projects item with the flag on: \(menuTitles(file))")
        XCTAssertTrue(file.menuItems["Open Project"].exists)
        XCTAssertTrue(menuItem("Save Session as", in: file).exists)
        closeMenus(app)

        _ = openCommandPalette(in: app)
        app.typeText("Project")
        XCTAssertTrue(
            waitFor({ self.paletteRows(containing: "Project", in: app).count > 0 }, timeout: 5),
            "the palette lists no Project rows with the flag on, so the flag-off absence check proves nothing"
        )
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
    }
}
