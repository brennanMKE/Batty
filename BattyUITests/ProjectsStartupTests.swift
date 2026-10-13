// ProjectsStartupTests.swift

import XCTest

/// Startup commands and the trust sheet (#0478, covering #0473). The
/// command a Project runs is `touch <marker>`, so the test waits on a file
/// the shell creates; nothing here waits on elapsed time.
nonisolated final class ProjectsStartupTests: ProjectsUITestCase {
    @MainActor
    private func sheet(in app: XCUIApplication) -> XCUIElement {
        element("project-startup-trust", in: app)
    }

    /// Text in the sheet is exposed through `value`, not `label`.
    @MainActor
    private func listsCommand(containing text: String, in app: XCUIApplication) -> Bool {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text)).firstMatch.exists
    }

    /// The sheet root's identifier can replace a control's own, so controls are also
    /// matched by their title.
    @MainActor
    private func sheetButton(_ identifier: String, title: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@ OR title == %@", identifier, title, title)).firstMatch
    }

    @MainActor
    private func waitForSheet(in app: XCUIApplication) {
        XCTAssertTrue(sheet(in: app).waitForExistence(timeout: 10), "the startup-command trust sheet did not appear")
    }

    @MainActor
    private func clickSheetButton(_ identifier: String, _ title: String, in app: XCUIApplication) {
        let button = sheetButton(identifier, title: title, in: app)
        XCTAssertTrue(button.waitForExistence(timeout: 10), "no \(title) button in the trust sheet")
        button.click()
    }

    @MainActor
    func testTrustSheetGatesStartupCommandsAndRemembersApproval() throws {
        let root = try makeDirectory("runner-root")
        let first = scratch.appending(path: "ran-first")
        let edited = scratch.appending(path: "ran-edited")
        let command = "touch \(BattyCLI.shellQuoted(first.path))"
        let project = ProjectFixture.project(
            name: "Runner",
            root: root,
            layout: ProjectFixture.terminal([ProjectFixture.tab("Server", command: command)]),
            preset: "singlePane",
            runStartupCommands: true
        )
        let (app, _) = try launchApp(projects: [project])
        defer { app.terminate() }

        // Open Without Running: the Session opens, the command does not run.
        openThroughPicker("Runner", in: app)
        waitForSheet(in: app)
        XCTAssertTrue(listsCommand(containing: first.lastPathComponent, in: app), "the trust sheet does not list the command")
        XCTAssertNil(BattyCLI.topology().flatMap { sessions(named: "Runner", in: $0).first }, "a Session opened before the trust sheet was answered")
        clickSheetButton("project-startup-trust.open-without-running", "Open Without Running", in: app)
        var runner = try XCTUnwrap(waitForSessions(named: "Runner").first)
        XCTAssertTrue(waitFor({ !self.sheet(in: app).exists }, timeout: 5), "the sheet stayed up after Open Without Running")
        assertShellResponds(pane: runner.focusedPaneID, app: app)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path), "Open Without Running ran the startup command")
        XCTAssertNil(ProjectFixture.read(storeFile)?.first?["approvedCommandsHash"] as? String, "Open Without Running stored an approval")

        // Run Commands with the approval remembered.
        closeSession(runner.id)
        openThroughPicker("Runner", in: app)
        waitForSheet(in: app)
        let remember = app.checkBoxes.matching(NSPredicate(format: "identifier == %@ OR label BEGINSWITH %@", "project-startup-trust.remember", "Don")).firstMatch
        XCTAssertTrue(remember.waitForExistence(timeout: 5), "no remember toggle in the trust sheet")
        if !isChecked(remember) { remember.click() }
        XCTAssertTrue(isChecked(remember), "the remember toggle is off: \(remember.debugDescription)")
        clickSheetButton("project-startup-trust.run", "Run Commands", in: app)
        runner = try XCTUnwrap(waitForSessions(named: "Runner").first)
        XCTAssertTrue(BattyUITestHarness.waitForFile(at: first.path, timeout: 60), "Run Commands did not run the startup command")
        assertShellResponds(pane: runner.focusedPaneID, app: app)
        XCTAssertNotNil(ProjectFixture.read(storeFile)?.first?["approvedCommandsHash"] as? String, "the approval was not stored")

        // Approved: opening again runs without asking.
        try FileManager.default.removeItem(at: first)
        closeSession(runner.id)
        openThroughPicker("Runner", in: app)
        runner = try XCTUnwrap(waitForSessions(named: "Runner").first)
        XCTAssertTrue(BattyUITestHarness.waitForFile(at: first.path, timeout: 60), "the approved command did not run on the third open")
        XCTAssertFalse(sheet(in: app).exists, "the trust sheet appeared for an approved command set")

        // Editing the command brings the sheet back.
        openEditorFromFileMenu(in: app)
        click("project-editor.list.row.Runner", in: app)
        replaceText(in: "project-editor.tab.1.command", with: "touch \(BattyCLI.shellQuoted(edited.path))", app: app)
        click("project-editor.save", in: app)
        XCTAssertTrue(
            waitFor({ ProjectFixture.read(self.storeFile)?.first.map(ProjectFixture.commands(of:))?.first?.contains(edited.lastPathComponent) == true }, timeout: 10),
            "the edited command was not saved"
        )
        click("project-editor.cancel", in: app)
        XCTAssertTrue(waitFor({ !self.editorWindow(in: app).exists }, timeout: 10))

        closeSession(runner.id)
        openThroughPicker("Runner", in: app)
        waitForSheet(in: app)
        XCTAssertTrue(listsCommand(containing: edited.lastPathComponent, in: app), "the trust sheet does not list the edited command")
        clickSheetButton("project-startup-trust.open-without-running", "Open Without Running", in: app)
        _ = waitForSessions(named: "Runner")
        XCTAssertFalse(FileManager.default.fileExists(atPath: edited.path), "the unapproved edited command ran")
    }

    /// `/bin/sh` is not zsh or bash, so Batty loads no shell integration into it and it never
    /// reports OSC 7: the situation of #0479. The deadline is real time (10 s), so waits
    /// here are expectation timeouts used as failure guards, not sleeps.
    @MainActor
    private func waitingIndicator(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier == %@ OR label BEGINSWITH %@ OR title BEGINSWITH %@",
            "tab-startup-waiting", "Startup command not run", "Startup command not run"
        )).firstMatch
    }

    @MainActor
    private func chooseWaitingAction(_ title: String, in app: XCUIApplication) {
        let indicator = waitingIndicator(in: app)
        XCTAssertTrue(indicator.waitForExistence(timeout: 60), "the startup-command waiting indicator never appeared")
        indicator.click()
        let item = app.menuItems[title]
        XCTAssertTrue(item.waitForExistence(timeout: 10), "no \(title) in the waiting indicator's menu")
        item.click()
    }

    @MainActor
    func testShellThatNeverReportsShowsWaitingIndicatorWithRunNowAndDismiss() throws {
        let root = try makeDirectory("silent-root")
        let marker = scratch.appending(path: "ran-silent")
        let command = "touch \(BattyCLI.shellQuoted(marker.path))"
        let project = ProjectFixture.project(
            name: "Silent",
            root: root,
            layout: ProjectFixture.terminal([ProjectFixture.tab("Server", command: command)]),
            preset: "singlePane",
            runStartupCommands: true
        )
        let (app, _) = try launchApp(projects: [project], extraArguments: ["-co.sstools.Batty.defaultShell", "/bin/sh"])
        defer { app.terminate() }

        openThroughPicker("Silent", in: app)
        waitForSheet(in: app)
        let remember = app.checkBoxes.matching(NSPredicate(format: "identifier == %@ OR label BEGINSWITH %@", "project-startup-trust.remember", "Don")).firstMatch
        if remember.waitForExistence(timeout: 5), !isChecked(remember) { remember.click() }
        clickSheetButton("project-startup-trust.run", "Run Commands", in: app)
        var silent = try XCTUnwrap(waitForSessions(named: "Silent").first)

        // Run Now types the command once.
        chooseWaitingAction("Run Now", in: app)
        XCTAssertTrue(BattyUITestHarness.waitForFile(at: marker.path, timeout: 60), "Run Now did not run the startup command")
        XCTAssertTrue(waitFor({ !self.waitingIndicator(in: app).exists }, timeout: 10), "the indicator stayed after Run Now")
        assertShellResponds(pane: silent.focusedPaneID, app: app)

        // Dismiss types nothing.
        try FileManager.default.removeItem(at: marker)
        closeSession(silent.id)
        openThroughPicker("Silent", in: app)
        silent = try XCTUnwrap(waitForSessions(named: "Silent").first)
        chooseWaitingAction("Dismiss", in: app)
        XCTAssertTrue(waitFor({ !self.waitingIndicator(in: app).exists }, timeout: 10), "the indicator stayed after Dismiss")
        assertShellResponds(pane: silent.focusedPaneID, app: app)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "Dismiss still ran the startup command")
    }
}
