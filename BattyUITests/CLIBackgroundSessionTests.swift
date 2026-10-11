// CLIBackgroundSessionTests.swift

import XCTest

/// CLI verbs aimed at a Session that is not selected (#0447): the focus
/// verbs switch the selected Session and bring the window forward, and
/// `notify` takes the unseen path. Same relay and explicit-id rules as
/// `CLIRemoteControlTests`.
nonisolated final class CLIBackgroundSessionTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        BattyUITestHarness.sweepSentinels()
        scratch = try BattyCLI.makeScratchDirectory()
    }

    override func tearDownWithError() throws {
        BattyUITestHarness.sweepSentinels()
    }

    private func makeDirectory(_ name: String) throws -> URL {
        let url = scratch.appending(path: name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @MainActor
    private func focusSession(_ id: UUID) throws {
        BattyCLI.runExpectingSuccess(["session", "focus", id.uuidString])
        _ = try XCTUnwrap(BattyCLI.waitForTopology { $0.selectedSessionID == id }, "session focus \(id) did not select it")
    }

    @MainActor
    private func rowValue(_ name: String, in app: XCUIApplication) -> String? {
        // With an unseen badge the row's identifier is doubled
        // ("session-row.X-session-row.X"), so match it by prefix.
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "session-row.\(name)"))
            .firstMatch
        guard row.exists else { return nil }
        return (try? row.snapshot())?.value as? String
    }

    @MainActor
    private func attachTree(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(string: app.debugDescription)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// The text a Text exposes: its label, else its value.
    @MainActor
    private func text(of element: XCUIElement) -> String {
        if !element.label.isEmpty { return element.label }
        if let value = element.value as? String, !value.isEmpty { return value }
        return element.title
    }

    // MARK: - A.1 pane focus / tab focus across Sessions

    @MainActor
    func testPaneFocusAimedAtABackgroundSessionSwitchesTheSession() throws {
        let (app, _, initial) = try BattyCLI.launchConnected(from: Self.self)
        defer { app.terminate() }

        let first = try XCTUnwrap(initial.selectedSession)
        let (second, secondPane) = try BattyCLI.newSession(at: try makeDirectory("pane-focus-project"))
        let split = try XCTUnwrap(
            BattyCLI.runExpectingSuccess(["pane", "split", "-h", "--pane", secondPane.uuidString]).ids.last
        )
        _ = try XCTUnwrap(BattyCLI.waitForTopology { $0.session(second.id)?.pane(split) != nil })
        try focusSession(first.id)
        XCTAssertTrue(waitFor({ self.rowValue(first.name, in: app) == "selected" && self.rowValue(second.name, in: app) == "unselected" }, timeout: 10))

        BattyCLI.runExpectingSuccess(["pane", "focus", split.uuidString])
        let topology = try XCTUnwrap(BattyCLI.waitForTopology { $0.selectedSessionID == second.id }, "pane focus did not switch the selected Session")
        XCTAssertEqual(topology.session(second.id)?.focusedPaneID, split)
        XCTAssertTrue(
            waitFor({ self.rowValue(second.name, in: app) == "selected" && self.rowValue(first.name, in: app) == "unselected" }, timeout: 10),
            "the Sidebar selection did not follow pane focus"
        )
        XCTAssertTrue(
            waitFor({ BattyScreen.terminalPane(split, in: app).label == "focused" && BattyScreen.terminalPane(secondPane, in: app).label == "unfocused" }, timeout: 10),
            "the focused marker did not move to the targeted Pane"
        )
        BattyScreen.expectMatches(topology, in: app)
    }

    @MainActor
    func testTabFocusAimedAtABackgroundSessionSwitchesTheSession() throws {
        let (app, _, initial) = try BattyCLI.launchConnected(from: Self.self)
        defer { app.terminate() }

        let first = try XCTUnwrap(initial.selectedSession)
        let (second, secondPane) = try BattyCLI.newSession(at: try makeDirectory("tab-focus-project"))
        BattyCLI.runExpectingSuccess(["pane", "focus", secondPane.uuidString])
        _ = try XCTUnwrap(BattyCLI.waitForTopology { $0.selectedSessionID == second.id && $0.session(second.id)?.focusedPaneID == secondPane })
        let originalTab = try XCTUnwrap(second.pane(secondPane)?.activeTabID)

        app.typeKey("t", modifierFlags: [.command])
        let twoTabs = try XCTUnwrap(BattyCLI.waitForTopology { $0.pane(secondPane)?.tabIDs.count == 2 }, "Cmd-T did not add a Tab to the new Session")
        XCTAssertNotEqual(twoTabs.pane(secondPane)?.activeTabID, originalTab, "the new Tab should be active, so tab focus has something to change")

        try focusSession(first.id)
        BattyCLI.runExpectingSuccess(["tab", "focus", originalTab.uuidString])
        let topology = try XCTUnwrap(
            BattyCLI.waitForTopology { $0.selectedSessionID == second.id && $0.pane(secondPane)?.activeTabID == originalTab },
            "tab focus did not switch the Session and the active Tab"
        )
        XCTAssertEqual(topology.session(second.id)?.focusedPaneID, secondPane)
        XCTAssertTrue(
            waitFor({ self.rowValue(second.name, in: app) == "selected" && self.rowValue(first.name, in: app) == "unselected" }, timeout: 10),
            "the Sidebar selection did not follow tab focus"
        )
        BattyScreen.expectMatches(topology, in: app)
    }

    // MARK: - A.10 focus brings the window forward

    @MainActor
    func testFocusVerbsRestoreAMiniaturizedWindow() throws {
        let (app, _, initial) = try BattyCLI.launchConnected(from: Self.self)
        defer { app.terminate() }

        let session = try XCTUnwrap(initial.selectedSession)
        let window = app.windows.firstMatch
        func isOnScreen() -> Bool { window.exists && window.isHittable }
        XCTAssertTrue(waitFor({ isOnScreen() }, timeout: 10), "the window should start on screen")

        let target = session.focusedPaneID
        let verbs: [[String]] = [
            ["pane", "focus", target.uuidString],
            ["tab", "focus", try XCTUnwrap(session.pane(target)?.activeTabID).uuidString],
            ["session", "focus", session.id.uuidString],
        ]
        for arguments in verbs {
            window.buttons[XCUIIdentifierMinimizeWindow].click()
            XCTAssertTrue(waitFor({ !isOnScreen() }, timeout: 10), "the window did not miniaturize before batty \(arguments.joined(separator: " "))")

            BattyCLI.runExpectingSuccess(arguments)
            XCTAssertTrue(waitFor({ isOnScreen() }, timeout: 10), "batty \(arguments.joined(separator: " ")) did not bring the miniaturized window back")
            XCTAssertEqual(app.state, .runningForeground, "batty \(arguments.joined(separator: " ")) did not activate Batty")
        }
    }

    // MARK: - A.2 / A.7 notify aimed at a background Session

    @MainActor
    func testNotifyToABackgroundSessionIsUnseenAndCollapses() throws {
        let (app, _, initial) = try BattyCLI.launchConnected(from: Self.self)
        defer { app.terminate() }

        let first = try XCTUnwrap(initial.selectedSession)
        let (second, secondPane) = try BattyCLI.newSession(at: try makeDirectory("notify-background-project"))
        let secondTab = try XCTUnwrap(second.pane(secondPane)?.activeTabID)
        try focusSession(first.id)
        BattyScreen.openBellFeed(in: app)
        XCTAssertTrue(BattyScreen.bellEntryIDs(in: app).isEmpty)

        // The Sidebar row's accessibility value carries "N unseen" while the
        // Session has unseen bell events (the row folds its children, so the
        // exact surrounding text varies).
        func badgeCount(_ session: CLITopology.Session) -> String? {
            guard let value = rowValue(session.name, in: app),
                  let range = value.range(of: #"\d+(?= unseen)"#, options: .regularExpression)
            else { return nil }
            return String(value[range])
        }

        BattyCLI.runExpectingSuccess(["notify", "--title", "bg title", "--body", "bg body", "--tab", secondTab.uuidString])
        XCTAssertTrue(waitFor({ BattyScreen.bellEntryIDs(in: app).count == 1 }, timeout: 10), "notify to a background Session added no entry")
        let badgeShown = waitFor({ badgeCount(second) == "1" }, timeout: 10)
        if !badgeShown { attachTree("tree without unseen badge", app) }
        XCTAssertTrue(badgeShown, "the background Session's Sidebar row shows no unseen badge: \(String(describing: badgeCount(second)))")
        XCTAssertNil(badgeCount(first), "the selected Session must not be marked unseen")

        // The entry carries the notification's text and is attributed to the
        // targeted Session and Pane, not the selected one.
        let entryID = try XCTUnwrap(BattyScreen.bellEntryIDs(in: app).first)
        let message = BattyScreen.element("bell-feed-message.\(entryID)", in: app)
        XCTAssertTrue(message.waitForExistence(timeout: 10), "the entry shows no message")
        if text(of: message) != "bg title\nbg body" { attachTree("tree with unexpected message", app) }
        XCTAssertEqual(text(of: message), "bg title\nbg body")
        let path = BattyScreen.element("bell-feed-path.\(entryID)", in: app)
        XCTAssertTrue(path.waitForExistence(timeout: 10), "the entry shows no path")
        XCTAssertTrue(text(of: path).contains(second.name) && text(of: path).contains("Pane 1"), "the entry is attributed to \(text(of: path)), expected Session \(second.name)")

        // An identical notification to the same unseen Tab collapses into the
        // existing entry but still counts toward the unseen badge.
        BattyCLI.runExpectingSuccess(["notify", "--title", "bg title", "--body", "bg body", "--tab", secondTab.uuidString])
        XCTAssertTrue(waitFor({ badgeCount(second) == "2" }, timeout: 10), "a collapsed notification did not raise the unseen count: \(String(describing: badgeCount(second)))")
        XCTAssertEqual(BattyScreen.bellEntryIDs(in: app).count, 1, "an identical notification must collapse into one entry")

        // A different message is a new entry; --sound is accepted and posts
        // the same entry (its audible effect is not observable on screen).
        BattyCLI.runExpectingSuccess(["notify", "--title", "other title", "--sound", "--tab", secondTab.uuidString])
        XCTAssertTrue(waitFor({ BattyScreen.bellEntryIDs(in: app).count == 2 }, timeout: 10), "a different message did not add an entry")
        XCTAssertTrue(waitFor({ badgeCount(second) == "3" }, timeout: 10))
    }

    // MARK: - A.8 notify without --tab

    @MainActor
    func testNotifyWithoutTabTargetsTheFocusedPaneOrIsRefused() throws {
        let (app, _, initial) = try BattyCLI.launchConnected(from: Self.self)
        defer { app.terminate() }

        let session = try XCTUnwrap(initial.selectedSession)
        let secondPane = try XCTUnwrap(
            BattyCLI.runExpectingSuccess(["pane", "split", "-h", "--pane", session.focusedPaneID.uuidString]).ids.last
        )
        BattyCLI.runExpectingSuccess(["pane", "focus", secondPane.uuidString])
        _ = try XCTUnwrap(BattyCLI.waitForTopology { $0.session(session.id)?.focusedPaneID == secondPane })
        BattyScreen.openBellFeed(in: app)

        BattyCLI.runExpectingSuccess(["notify", "--title", "fallback title"])
        XCTAssertTrue(waitFor({ BattyScreen.bellEntryIDs(in: app).count == 1 }, timeout: 10), "notify with no --tab added no entry")
        let entryID = try XCTUnwrap(BattyScreen.bellEntryIDs(in: app).first)
        let message = BattyScreen.element("bell-feed-message.\(entryID)", in: app)
        XCTAssertTrue(message.waitForExistence(timeout: 10), "the entry shows no message")
        if text(of: message) != "fallback title" { attachTree("tree with unexpected message", app) }
        XCTAssertEqual(text(of: message), "fallback title")
        let path = BattyScreen.element("bell-feed-path.\(entryID)", in: app)
        XCTAssertTrue(path.waitForExistence(timeout: 10))
        XCTAssertTrue(text(of: path).contains("Pane 2"), "the fallback must use the focused Pane (the second), saw \(text(of: path))")

        // With a non-terminal Pane focused there is no Tab to attribute to.
        let view = try XCTUnwrap(
            BattyCLI.runExpectingSuccess(["pane", "split", "--view", "system-metrics", "--pane", secondPane.uuidString]).ids.last
        )
        BattyCLI.runExpectingSuccess(["pane", "focus", view.uuidString])
        _ = try XCTUnwrap(BattyCLI.waitForTopology { $0.session(session.id)?.focusedPaneID == view })
        let refused = BattyCLI.run(["notify", "--title", "no tab"])
        XCTAssertEqual(refused.status, 4, "notify with no --tab and a non-terminal Pane focused must exit 4: \(refused.summary)")

        // The valid notify that follows is the barrier: requests are served in
        // order, so a wrongly added entry would already show as a third.
        let tab = try XCTUnwrap(initial.selectedSession?.pane(session.focusedPaneID)?.activeTabID)
        BattyCLI.runExpectingSuccess(["notify", "--title", "barrier", "--tab", tab.uuidString])
        XCTAssertTrue(waitFor({ BattyScreen.bellEntryIDs(in: app).count >= 2 }, timeout: 10))
        XCTAssertEqual(BattyScreen.bellEntryIDs(in: app).count, 2, "the refused notify must not add an entry")
    }
}
