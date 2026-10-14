// ProjectsEditorTests.swift

import XCTest

/// The Project Editor and Save Session as Project (#0478, covering #0474 and
/// #0476).
nonisolated final class ProjectsEditorTests: ProjectsUITestCase {
    private func existingProject() throws -> [String: Any] {
        ProjectFixture.project(
            name: "Existing",
            root: try makeDirectory("existing-root"),
            layout: ProjectFixture.split("horizontal", [ProjectFixture.terminal(), ProjectFixture.terminal()]),
            preset: "horizontalSplit"
        )
    }

    // MARK: - 5. Project Editor

    @MainActor
    func testEditProjectsMenuOpensTheEditorOnTheStoredProjects() throws {
        let (app, _) = try launchApp(projects: [try existingProject()])
        defer { app.terminate() }

        openEditorFromFileMenu(in: app)
        XCTAssertTrue(element("project-editor.list.row.Existing", in: app).waitForExistence(timeout: 5), "the editor does not list the stored Project")

        let windowMenu = openMenu("Window", in: app)
        XCTAssertTrue(
            windowMenu.menuItems.matching(NSPredicate(format: "title == %@", "Projects")).firstMatch.exists
                || menuTitles(windowMenu).contains("Projects"),
            "the Window menu does not list the open Project Editor: \(menuTitles(windowMenu))"
        )
        closeMenus(app)
    }

    @MainActor
    func testEditorCreatesAProjectAndSaveAndOpenOpensIt() throws {
        let root = try makeDirectory("fresh-root")
        _ = try BattyCLI.makeGitRepository(in: root, named: "repo")
        _ = try makeDirectory("sub", in: root)
        let (app, _) = try launchApp(projects: [try existingProject()])
        defer { app.terminate() }

        openEditorFromFileMenu(in: app)
        click("project-editor.new-project", in: app)
        replaceText(in: "project-editor.name", with: "Fresh Grid", app: app)
        replaceText(in: "project-editor.root", with: root.path, app: app)
        click("project-editor.layout.twoByTwoGrid", in: app)
        XCTAssertTrue(paneCard(4, in: app).waitForExistence(timeout: 5), "the 2x2 layout did not give four Pane cards")
        XCTAssertFalse(paneCard(5, in: app).exists)

        clickPaneCard(2, in: app)
        click("project-editor.kind.git-status", in: app)
        replaceText(in: "project-editor.repository", with: "repo", app: app)

        clickPaneCard(1, in: app)
        click("project-editor.add-tab", in: app)
        replaceText(in: "project-editor.tab.2.title", with: "Second", app: app)
        replaceText(in: "project-editor.tab.2.directory", with: "sub", app: app)

        let saveAndOpen = element("project-editor.save-open", in: app)
        XCTAssertTrue(waitFor({ saveAndOpen.isEnabled }, timeout: 10), "Save & Open stayed disabled for a valid Project: \(element("project-editor.save-error", in: app).debugDescription)")
        saveAndOpen.click()

        XCTAssertTrue(waitFor({ !self.editorWindow(in: app).exists }, timeout: 10), "Save & Open did not close the editor")
        let session = try XCTUnwrap(waitForSessions(named: "Fresh Grid").first)
        let topology = try XCTUnwrap(BattyCLI.waitForTopology { $0.session(session.id)?.visiblePanes.count == 4 })
        let opened = try XCTUnwrap(topology.session(session.id))
        XCTAssertEqual(opened.panes.map(\.kind), ["terminal", "git-status", "terminal", "terminal"])
        XCTAssertEqual(opened.panes.map(\.tabIDs.count), [2, 0, 1, 1])
        XCTAssertTrue(BattyUITestHarness.tabChip(named: "Second", in: app).waitForExistence(timeout: 10), "no Tab chip titled Second")
        XCTAssertTrue(BattyUITestHarness.sessionRow(named: "Fresh Grid", in: app).waitForExistence(timeout: 5))
        XCTAssertEqual(Set(ProjectFixture.names(in: storeFile)), ["Existing", "Fresh Grid"])

        // The second Tab opens in the folder the editor gave it.
        BattyUITestHarness.tabChip(named: "Second", in: app).click()
        let pwdFile = scratch.appending(path: "pwd-second")
        runInTerminal("pwd > \(BattyCLI.shellQuoted(pwdFile.path))", pane: opened.panes[0].id, app: app)
        XCTAssertTrue(BattyUITestHarness.waitForFile(at: pwdFile.path, timeout: 30), "the second Tab's shell did not respond")
        XCTAssertTrue(
            waitFor({ BattyCLI.readTrimmed(pwdFile.path)?.hasSuffix("/sub") == true }, timeout: 10),
            "the second Tab did not open in sub: \(BattyCLI.readTrimmed(pwdFile.path) ?? "nil")"
        )
    }

    @MainActor
    func testCancelLeavesTheStoredProjectUnchanged() throws {
        let (app, _) = try launchApp(projects: [try existingProject()])
        defer { app.terminate() }

        openEditorFromFileMenu(in: app)
        click("project-editor.list.row.Existing", in: app)
        replaceText(in: "project-editor.name", with: "Existing Changed", app: app)
        click("project-editor.cancel", in: app)
        XCTAssertTrue(waitFor({ !self.editorWindow(in: app).exists }, timeout: 10), "Cancel did not close the editor")

        XCTAssertEqual(ProjectFixture.names(in: storeFile), ["Existing"], "Cancel wrote the edit to the store")

        openThroughPicker("Existing", in: app)
        let session = try XCTUnwrap(waitForSessions(named: "Existing").first)
        XCTAssertEqual(try XCTUnwrap(BattyCLI.topology()).session(session.id)?.panes.count, 2, "the reopened Project lost its layout")
        XCTAssertTrue(BattyCLI.topology()?.sessions.contains { $0.name == "Existing Changed" } != true)
    }

    // MARK: - 6. Save Session as Project

    @MainActor
    func testSidebarSaveAsProjectRoundTripsTheSessionShape() throws {
        let (app, _) = try launchApp(script: [
            ["intent": "createSession", "name": "Built"],
            ["intent": "splitHorizontal"],
            ["intent": "createTab"],
            ["intent": "renameActiveTab", "to": "Build"],
            ["intent": "createPane", "kind": "system-metrics"],
        ])
        defer { app.terminate() }

        let built = try XCTUnwrap(BattyCLI.waitForTopology(timeout: 20) { $0.sessions.first { $0.name == "Built" }?.visiblePanes.count == 3 }?.sessions.first { $0.name == "Built" })
        // Hand-sized: Panes open at equal sizes, so drag the divider right of the
        // leftmost terminal Pane. Split ratios are not captured by Save as Project.
        let terminals = built.panes.filter { $0.kind == "terminal" }
        let leftmost = try XCTUnwrap(terminals.min { BattyScreen.terminalPane($0.id, in: app).frame.minX < BattyScreen.terminalPane($1.id, in: app).frame.minX })
        let leftFrame = BattyScreen.terminalPane(leftmost.id, in: app).frame
        let window = app.windows.firstMatch
        let origin = window.coordinate(withNormalizedOffset: .zero)
        func point(_ x: CGFloat, _ y: CGFloat) -> XCUICoordinate {
            origin.withOffset(CGVector(dx: x - window.frame.minX, dy: y - window.frame.minY))
        }
        point(leftFrame.maxX + 3, leftFrame.midY).press(forDuration: 0.05, thenDragTo: point(leftFrame.maxX + 63, leftFrame.midY))

        func spread(_ topology: CLITopology) -> CGFloat {
            let widths = topology.session(built.id)?.panes.compactMap { $0.frame?.width } ?? []
            return (widths.max() ?? 0) - (widths.min() ?? 0)
        }
        let unequal = try XCTUnwrap(
            BattyCLI.waitForTopology(includeDimensions: true) { spread($0) > 20 },
            "dragging the divider did not make the Panes unequal (equal sizing would prove nothing)"
        )
        let before = try XCTUnwrap(unequal.session(built.id))
        let kinds = before.panes.map(\.kind)
        let tabCounts = before.panes.map(\.tabIDs.count)
        XCTAssertEqual(kinds.filter { $0 == "system-metrics" }.count, 1)
        XCTAssertEqual(tabCounts.filter { $0 == 2 }.count, 1, "exactly one Pane has the added Tab: \(tabCounts)")

        let row = BattyUITestHarness.sessionRow(named: "Built", in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.rightClick()
        let saveItem = app.menuItems.matching(NSPredicate(format: "title BEGINSWITH %@", "Save as Project")).firstMatch
        XCTAssertTrue(saveItem.waitForExistence(timeout: 5), "the Sidebar menu has no Save as Project...: \(app.menuItems.allElementsBoundByIndex.map(\.title))")
        saveItem.click()

        XCTAssertTrue(editorWindow(in: app).waitForExistence(timeout: 10), "Save as Project did not open the editor")
        XCTAssertTrue(paneCard(3, in: app).waitForExistence(timeout: 5), "the draft does not have the Session's three Panes")
        XCTAssertFalse(paneCard(4, in: app).exists)
        XCTAssertTrue((ProjectFixture.read(storeFile) ?? []).isEmpty, "the draft was stored before Save")

        let name = try XCTUnwrap(element("project-editor.name", in: app).value as? String)
        XCTAssertFalse(name.isEmpty)
        let save = element("project-editor.save", in: app)
        XCTAssertTrue(waitFor({ save.isEnabled }, timeout: 10), "Save stayed disabled: \(element("project-editor.save-error", in: app).debugDescription)")
        save.click()
        XCTAssertTrue(waitFor({ ProjectFixture.names(in: self.storeFile) == [name] }, timeout: 10), "Save did not store \(name)")
        click("project-editor.cancel", in: app)
        XCTAssertTrue(waitFor({ !self.editorWindow(in: app).exists }, timeout: 10))

        closeSession(built.id)
        openThroughPicker(name, in: app)
        let reopened = try XCTUnwrap(waitForSessions(named: name).first)
        let after = try XCTUnwrap(BattyCLI.waitForTopology { $0.session(reopened.id)?.visiblePanes.count == 3 })
        let afterSession = try XCTUnwrap(after.session(reopened.id))
        XCTAssertEqual(afterSession.panes.map(\.kind), kinds, "Pane kinds differ after the round trip")
        XCTAssertEqual(afterSession.panes.map(\.tabIDs.count), tabCounts, "Tab counts differ after the round trip")
        XCTAssertTrue(BattyUITestHarness.tabChip(named: "Build", in: app).waitForExistence(timeout: 10), "the renamed Tab lost its title")

        let sized = try XCTUnwrap(BattyCLI.waitForTopology(includeDimensions: true) { topology in
            let widths = topology.session(reopened.id)?.panes.compactMap { $0.frame?.width } ?? []
            return widths.count >= 2 && (widths.max() ?? 0) - (widths.min() ?? 0) < 12
        }, "the reopened Project did not open at equal sizes")
        XCTAssertEqual(sized.session(reopened.id)?.panes.count, 3)
    }

    @MainActor
    func testCommandsOffHintTracksTheToggleWhenCommandsExist() throws {
        let withCommand = ProjectFixture.project(
            name: "Commanded",
            root: try makeDirectory("commanded-root"),
            layout: ProjectFixture.terminal([ProjectFixture.tab(command: "claude")]),
            runStartupCommands: false
        )
        let withoutCommand = ProjectFixture.project(
            name: "Bare",
            root: try makeDirectory("bare-root"),
            layout: ProjectFixture.terminal(),
            runStartupCommands: false
        )
        let (app, _) = try launchApp(projects: [withCommand, withoutCommand])
        defer { app.terminate() }

        openEditorFromFileMenu(in: app)
        let hint = element("project-editor.commands-off-hint", in: app)

        click("project-editor.list.row.Commanded", in: app)
        XCTAssertTrue(hint.waitForExistence(timeout: 5), "commands with the toggle off show no hint")
        click("project-editor.run-commands", in: app)
        XCTAssertTrue(waitFor({ !hint.exists }, timeout: 5), "the hint stayed after the toggle was turned on")
        click("project-editor.run-commands", in: app)
        XCTAssertTrue(hint.waitForExistence(timeout: 5), "the hint did not return when the toggle went off again")

        click("project-editor.list.row.Bare", in: app)
        XCTAssertTrue(element("project-editor.run-commands", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(waitFor({ !hint.exists }, timeout: 5), "a Project with no commands shows the hint")
    }

    @MainActor
    func testSavedSessionProjectHasTheRunToggleOn() throws {
        let (app, _) = try launchApp(script: [["intent": "createSession", "name": "Toggled"]])
        defer { app.terminate() }

        let row = BattyUITestHarness.sessionRow(named: "Toggled", in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.rightClick()
        let saveItem = app.menuItems.matching(NSPredicate(format: "title BEGINSWITH %@", "Save as Project")).firstMatch
        XCTAssertTrue(saveItem.waitForExistence(timeout: 5))
        saveItem.click()

        XCTAssertTrue(editorWindow(in: app).waitForExistence(timeout: 10))
        let toggle = element("project-editor.run-commands", in: app)
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertTrue(isChecked(toggle), "the captured draft starts with the run toggle off")
        let save = element("project-editor.save", in: app)
        XCTAssertTrue(waitFor({ save.isEnabled }, timeout: 10))
        save.click()
        XCTAssertTrue(waitFor({ (ProjectFixture.read(self.storeFile) ?? []).count == 1 }, timeout: 10))
        let stored = try XCTUnwrap(ProjectFixture.read(storeFile)?.first)
        XCTAssertEqual(stored["runStartupCommandsOnOpen"] as? Bool, true)
    }

    // MARK: - 7. Command Palette

    @MainActor
    func testCommandPaletteSaveSessionAsProjectOpensTheEditor() throws {
        let (app, _) = try launchApp()
        defer { app.terminate() }

        _ = openCommandPalette(in: app)
        app.typeText("Save Session as Project")
        let row = app.staticTexts["Save Session as Project\u{2026}"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), "the palette has no Save Session as Project... row")
        row.click()
        XCTAssertTrue(editorWindow(in: app).waitForExistence(timeout: 10), "the palette row did not open the editor")
        XCTAssertTrue(element("project-editor.name", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue((ProjectFixture.read(storeFile) ?? []).isEmpty, "the draft was stored before Save")
    }
}
