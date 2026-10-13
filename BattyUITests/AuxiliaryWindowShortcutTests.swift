// AuxiliaryWindowShortcutTests.swift

import XCTest

/// Menu chords pressed while Settings or Help is the key window (#0480).
/// Both are non-content windows, so `BattyShortcuts` declines the chord and
/// AppKit hands it to the main menu, whose items used to resolve the most
/// recently key content window behind them.
///
/// The topology is read through the embedded CLI. "Nothing happened" is a
/// negative, so it is proven by ordering rather than by waiting: after the
/// chords the test performs a real action in the content window (File > Tab
/// > New Tab, a menu click that travels the same event queue the chords did)
/// and waits for that action's effect. The final topology must be exactly the
/// baseline plus that one Tab.
nonisolated final class AuxiliaryWindowShortcutTests: ProjectsUITestCase {
    private enum Auxiliary: String {
        case settings = "Settings"
        case help = "Help"
    }

    private struct Chord {
        let name: String
        let key: String
        let modifiers: XCUIElement.KeyModifierFlags
    }

    /// Every chord whose menu item changes a Session the content window shows.
    /// Cmd-V is covered by its own test because its effect is invisible to the
    /// topology.
    private static let sessionChords: [Chord] = [
        Chord(name: "Exit Shell (Shift-Cmd-X)", key: "x", modifiers: [.command, .shift]),
        Chord(name: "New Tab (Cmd-T)", key: "t", modifiers: [.command]),
        Chord(name: "Split Horizontally (Cmd-D)", key: "d", modifiers: [.command]),
        Chord(name: "Split Vertically (Shift-Cmd-D)", key: "d", modifiers: [.command, .shift]),
        Chord(name: "Open Git Status (Cmd-G)", key: "g", modifiers: [.command]),
        Chord(name: "Open Process Status (Cmd-J)", key: "j", modifiers: [.command]),
        Chord(name: "Open System Metrics (Cmd-E)", key: "e", modifiers: [.command]),
        Chord(name: "New Session (Cmd-N)", key: "n", modifiers: [.command]),
        Chord(name: "Focus Pane Left (Option-Cmd-Left)", key: XCUIKeyboardKey.leftArrow.rawValue, modifiers: [.command, .option]),
        Chord(name: "Show Next Tab (Shift-Cmd-])", key: "]", modifiers: [.command, .shift]),
        Chord(name: "Select Tab 1 (Option-Cmd-1)", key: "1", modifiers: [.command, .option]),
        Chord(name: "Move Split Divider Left (Ctrl-Cmd-Left)", key: XCUIKeyboardKey.leftArrow.rawValue, modifiers: [.command, .control]),
    ]

    // MARK: - Helpers

    @MainActor
    private func contentWindowIdentifier(in app: XCUIApplication) -> String {
        app.windows.firstMatch.identifier
    }

    @MainActor
    private func auxiliaryWindow(in app: XCUIApplication, contentIdentifier: String) -> XCUIElement {
        app.windows.matching(NSPredicate(format: "identifier != %@", contentIdentifier)).firstMatch
    }

    /// Opens the window and makes sure no text field is first responder, so
    /// Cmd-V is not absorbed by a field.
    @MainActor
    private func open(_ auxiliary: Auxiliary, in app: XCUIApplication, contentIdentifier: String) -> XCUIElement {
        switch auxiliary {
        case .settings:
            app.typeKey(",", modifierFlags: [.command])
        case .help:
            let menu = openMenu("Help", in: app)
            menuItem("Batty Help", in: menu).click()
        }
        let window = auxiliaryWindow(in: app, contentIdentifier: contentIdentifier)
        XCTAssertTrue(window.waitForExistence(timeout: 10), "\(auxiliary.rawValue) did not open")
        let pane = window.toolbars.buttons["Appearance"]
        if auxiliary == .settings, pane.exists {
            pane.click()
        } else {
            window.click()
        }
        return window
    }

    private func describe(_ topology: CLITopology) -> String {
        topology.sessions.map { session in
            let panes = session.panes.map { pane in
                let active = pane.tabIDs.firstIndex(of: pane.activeTabID).map(String.init) ?? "?"
                return "\(pane.kind)[\(pane.tabIDs.count) tab(s), active \(active)\(pane.isFocused ? ", focused" : "")]"
            }.joined(separator: ", ")
            return "\(session.name): \(panes)"
        }.joined(separator: " | ")
    }

    /// Everything a chord could have changed in the content window: Sessions,
    /// Panes, their Tabs, the active Tab, the focused Pane and the divider.
    private func fingerprint(_ topology: CLITopology) -> [String] {
        topology.sessions.flatMap { session in
            session.panes.map { pane in
                let width = pane.frame.map { String(Int($0.width.rounded())) } ?? "-"
                return "\(session.id) \(pane.id) \(pane.kind) tabs=\(pane.tabIDs.map(\.uuidString).joined(separator: ",")) active=\(pane.activeTabID) focused=\(pane.isFocused) width=\(width)"
            }
        }
    }

    /// Two Panes of two Tabs each, focus in the right one, so Cmd-T, Cmd-W,
    /// Exit Shell, focus moves, Tab selection and the divider all have
    /// something to change.
    @MainActor
    private func launchWithTwoPanes() throws -> (app: XCUIApplication, baseline: CLITopology, pane: UUID, session: UUID) {
        let (app, initial) = try launchApp()
        let session = try XCTUnwrap(initial?.selectedSession)
        let first = try XCTUnwrap(session.panes.first)
        app.typeKey("t", modifierFlags: [.command])
        _ = BattyCLI.waitForTopology { $0.session(session.id)?.pane(first.id)?.tabIDs.count == 2 }
        app.typeKey("d", modifierFlags: [.command])
        _ = BattyCLI.waitForTopology { $0.session(session.id)?.panes.count == 2 }
        app.typeKey("t", modifierFlags: [.command])
        let baseline = try XCTUnwrap(
            BattyCLI.waitForTopology(includeDimensions: true) { $0.session(session.id)?.panes.map(\.tabIDs.count) == [2, 2] },
            "the two-Pane setup did not settle"
        )
        let focused = try XCTUnwrap(baseline.session(session.id)?.focusedPaneID)
        assertShellResponds(pane: focused, app: app)
        return (app, baseline, focused, session.id)
    }

    /// Opens File > Tab from the content window once the auxiliary window is
    /// gone. Opening a menu is a real event that travels the queue the chords
    /// did, so reading the topology while it is open sees every chord's
    /// effect; the menu then proves New Tab is enabled and works.
    @MainActor
    private func checkContentWindowThenNewTab(
        in app: XCUIApplication, baseline: CLITopology, session: UUID, pane: UUID, after what: String
    ) throws {
        let menu = openMenu("Tab", in: app)
        let item = menuItem("New Tab", in: menu)
        XCTAssertTrue(item.isEnabled, "New Tab is disabled once the auxiliary window closed")

        let now = try XCTUnwrap(BattyCLI.topology(includeDimensions: true))
        XCTAssertEqual(
            fingerprint(now), fingerprint(baseline),
            "chords pressed in \(what) changed the content window.\nbefore: \(describe(baseline))\nafter:  \(describe(now))"
        )

        item.click()
        let added = BattyCLI.waitForTopology { $0.session(session)?.pane(pane)?.tabIDs.count == 3 }
        XCTAssertNotNil(added, "New Tab from the Tab menu added no Tab after the auxiliary window closed")
    }

    // MARK: - Chords

    @MainActor
    private func assertChordsLeaveContentWindowAlone(_ auxiliary: Auxiliary) throws {
        let (app, baseline, pane, session) = try launchWithTwoPanes()
        defer { app.terminate() }
        let contentID = contentWindowIdentifier(in: app)
        _ = open(auxiliary, in: app, contentIdentifier: contentID)

        for chord in Self.sessionChords {
            app.typeKey(chord.key, modifierFlags: chord.modifiers)
        }
        app.typeKey("w", modifierFlags: [.command])
        XCTAssertTrue(
            waitFor({ !self.auxiliaryWindow(in: app, contentIdentifier: contentID).exists }, timeout: 10),
            "Cmd-W did not close the \(auxiliary.rawValue) window"
        )

        try checkContentWindowThenNewTab(in: app, baseline: baseline, session: session, pane: pane, after: auxiliary.rawValue)

        // If `exit` reached the shell, its Tab closes only once the shell process
        // has exited, asynchronously to the chord, so the fingerprint read above
        // could miss it; a shell that still answers proves `exit` was never typed.
        assertShellResponds(pane: pane, app: app)
    }

    @MainActor
    func testSettingsKeyChordsLeaveTheContentWindowAlone() throws {
        try assertChordsLeaveContentWindowAlone(.settings)
    }

    @MainActor
    func testHelpKeyChordsLeaveTheContentWindowAlone() throws {
        try assertChordsLeaveContentWindowAlone(.help)
    }

    // MARK: - Paste

    @MainActor
    private func assertPasteDoesNotReachTerminal(_ auxiliary: Auxiliary) throws {
        let (app, _, pane, _) = try launchWithTwoPanes()
        defer { app.terminate() }
        let contentID = contentWindowIdentifier(in: app)

        let pasted = scratch.appending(path: "pasted-\(UUID().uuidString.prefix(8))")
        let source = scratch.appending(path: "clip.txt")
        try "touch \(BattyCLI.shellQuoted(pasted.path))".write(to: source, atomically: true, encoding: .utf8)
        runInTerminal("pbcopy < \(BattyCLI.shellQuoted(source.path))", pane: pane, app: app)
        runInTerminal("true", pane: pane, app: app)

        _ = open(auxiliary, in: app, contentIdentifier: contentID)
        app.typeKey("v", modifierFlags: [.command])
        app.typeKey("w", modifierFlags: [.command])
        XCTAssertTrue(
            waitFor({ !self.auxiliaryWindow(in: app, contentIdentifier: contentID).exists }, timeout: 10),
            "Cmd-W did not close the \(auxiliary.rawValue) window"
        )

        // If the paste reached the shell, the command line holds `touch <pasted>`
        // and this Return runs it. The marker that follows is created after it,
        // so by the time the marker exists the pasted command has had its turn.
        let terminal = BattyScreen.terminalPane(pane, in: app)
        XCTAssertTrue(terminal.waitForExistence(timeout: 10))
        terminal.click()
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
        assertShellResponds(pane: pane, app: app)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: pasted.path),
            "Cmd-V pressed in \(auxiliary.rawValue) pasted the clipboard into the terminal behind it"
        )
    }

    @MainActor
    func testSettingsKeyPasteDoesNotReachTheTerminal() throws {
        try assertPasteDoesNotReachTerminal(.settings)
    }

    @MainActor
    func testHelpKeyPasteDoesNotReachTheTerminal() throws {
        try assertPasteDoesNotReachTerminal(.help)
    }
}
