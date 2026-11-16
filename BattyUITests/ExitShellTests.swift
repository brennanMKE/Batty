// ExitShellTests.swift

import XCTest

/// Exit Shell must end zsh with bracketed paste left at its default, proven by the Tab
/// leaving the CLI topology (#0644). Each test pins `/bin/zsh` and checks the Tab's shell
/// really is zsh with `zle_bracketed_paste` set before exiting, so a failure cannot come
/// from the VM user's login shell. Waits are bounded failure guards, not sleeps. Runs only
/// through `tools/run-ui-tests-vm.sh`.
nonisolated final class ExitShellTests: ProjectsUITestCase {
    private struct Fixture {
        let app: XCUIApplication
        let session: UUID
        let pane: UUID
        let exiting: UUID
    }

    /// Launches under zsh, opens a second Tab in the focused Pane so closing one leaves the
    /// Pane standing, and proves the new Tab's shell is zsh with bracketed paste on.
    @MainActor
    private func launchZshWithTwoTabs() throws -> Fixture {
        let (app, launched) = try launchApp(extraArguments: ["-co.sstools.Batty.defaultShell", "/bin/zsh"])
        let initial = try XCTUnwrap(launched?.selectedSession ?? launched?.sessions.first, "no Session after launch")
        let pane = initial.focusedPaneID
        let initialTabIDs = try XCTUnwrap(initial.pane(pane)?.tabIDs, "the focused Pane is not in the topology")
        XCTAssertEqual(initialTabIDs.count, 1, "the focused Pane did not start with one Tab")

        app.typeKey("t", modifierFlags: [.command])
        let settled = try XCTUnwrap(
            BattyCLI.waitForTopology { $0.session(initial.id)?.pane(pane)?.tabIDs.count == 2 },
            "Cmd-T did not open a second Tab in the focused Pane"
        )
        let exiting = try XCTUnwrap(settled.session(initial.id)?.pane(pane)?.activeTabID)
        XCTAssertFalse(initialTabIDs.contains(exiting), "the new Tab did not become the active Tab")

        let marker = scratch.appending(path: "zsh-bracketed-paste")
        runInTerminal(
            "[ -n \"$ZSH_VERSION\" ] && (( ${+zle_bracketed_paste} )) && touch \(BattyCLI.shellQuoted(marker.path))",
            pane: pane,
            app: app
        )
        XCTAssertTrue(
            BattyUITestHarness.waitForFile(at: marker.path, timeout: 30),
            "the Tab's shell is not zsh with bracketed paste on (or it did not run a typed command)"
        )
        return Fixture(app: app, session: initial.id, pane: pane, exiting: exiting)
    }

    /// Waits for the exited Tab to leave the Pane. If it does not, presses one extra Return
    /// in the terminal to tell "exit sat in zsh's line editor" apart from any other failure.
    @MainActor
    private func assertExitShellClosed(_ fixture: Fixture, via: String, file: StaticString = #filePath, line: UInt = #line) {
        let session = fixture.session, pane = fixture.pane, exiting = fixture.exiting
        let predicate: (CLITopology) -> Bool = { topology in
            guard let p = topology.session(session)?.pane(pane) else { return false }
            return p.tabIDs.count == 1 && !p.tabIDs.contains(exiting)
        }
        if BattyCLI.waitForTopology(timeout: 15, predicate) != nil { return }

        let terminal = BattyScreen.terminalPane(pane, in: fixture.app)
        if terminal.exists { terminal.click() }
        pressReturn(in: fixture.app)
        if BattyCLI.waitForTopology(timeout: 15, predicate) != nil {
            XCTFail(
                "\(via) did not run exit: the Tab closed only after an extra Return, so exit sat in zsh's line editor (bracketed paste)",
                file: file,
                line: line
            )
        } else {
            let tabs = BattyCLI.topology()?.session(session)?.pane(pane)?.tabIDs ?? []
            XCTFail("\(via) did not end the shell, even after an extra Return; Pane tabs: \(tabs)", file: file, line: line)
        }
    }

    @MainActor
    func testExitShellShortcutEndsZshAndClosesTheTab() throws {
        let fixture = try launchZshWithTwoTabs()
        defer { fixture.app.terminate() }

        fixture.app.typeKey("x", modifierFlags: [.command, .shift])
        assertExitShellClosed(fixture, via: "Shift-Cmd-X")
    }

    @MainActor
    func testExitShellMenuItemEndsZshAndClosesTheTab() throws {
        let fixture = try launchZshWithTwoTabs()
        defer { fixture.app.terminate() }

        let menu = openMenu("Tab", in: fixture.app)
        let item = menuItem("Exit Shell", in: menu)
        XCTAssertTrue(item.waitForExistence(timeout: 5), "no Exit Shell item in the Tab menu: \(menuTitles(menu))")
        XCTAssertTrue(item.isEnabled, "Tab > Exit Shell is disabled with a terminal Tab focused")
        item.click()
        assertExitShellClosed(fixture, via: "Tab > Exit Shell")
    }

    /// The palette's `sendExit(in:)` path runs while the palette's own sheet is attached.
    @MainActor
    func testExitShellPaletteCommandEndsZshAndClosesTheTab() throws {
        let fixture = try launchZshWithTwoTabs()
        let app = fixture.app
        defer { app.terminate() }

        _ = openCommandPalette(in: app)
        app.typeText("Exit Shell")
        XCTAssertTrue(
            paletteRows(containing: "Exit Shell", in: app).firstMatch.waitForExistence(timeout: 5),
            "no Exit Shell row in the Command Palette"
        )
        pressReturn(in: app)
        XCTAssertTrue(
            waitFor({ !self.element("command-palette.root", in: app).exists }, timeout: 5),
            "the Command Palette did not close after Return on Exit Shell"
        )
        assertExitShellClosed(fixture, via: "Command Palette > Exit Shell")
    }
}
