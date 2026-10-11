// CLIRemoteControlTests.swift

import XCTest

/// Drives the real embedded `batty` CLI against the app XCUITest launched
/// (#0413) and asserts the on-screen result through accessibility
/// identifiers, not just exit codes or `list` output. Terminal-Pane and
/// Session verbs live here; the non-terminal `--view` kinds are in
/// `CLIViewPaneTests`.
///
/// Every CLI call goes through the guest-only relay (`BattyCLI.run`), so it
/// carries no `BATTY_*` environment: every target is an explicit id.
nonisolated final class CLIRemoteControlTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        BattyUITestHarness.sweepSentinels()
        scratch = try BattyCLI.makeScratchDirectory()
    }

    override func tearDownWithError() throws {
        BattyUITestHarness.sweepSentinels()
    }

    // MARK: - Helpers

    @MainActor
    private func launch() throws -> (app: XCUIApplication, appURL: URL, initial: CLITopology) {
        let app = BattyUITestHarness.launchBatty()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10), "Batty did not open a window")
        let (appURL, initial) = try BattyCLI.connect(to: app, from: CLIRemoteControlTests.self)
        return (app, appURL, initial)
    }

    private func makeDirectory(_ name: String) throws -> URL {
        let url = scratch.appending(path: name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @MainActor
    private func frame(ofTerminalPane id: UUID, in app: XCUIApplication) -> CGRect {
        BattyScreen.terminalPane(id, in: app).frame
    }

    /// `split` of a terminal Pane: prints the new id, exits 0.
    @MainActor
    private func splitTerminal(_ flag: String, of paneID: UUID, extra: [String] = []) throws -> UUID {
        let result = BattyCLI.runExpectingSuccess(["pane", "split", flag, "--pane", paneID.uuidString] + extra)
        return try XCTUnwrap(result.ids.last, "pane split printed no id: \(result.summary)")
    }

    // MARK: - Connection

    /// The precondition for every other test here: the CLI is talking to the
    /// process XCUITest launched, not some other instance (#0361).
    @MainActor
    func testCLITalksToTheLaunchedApp() throws {
        let (app, _, initial) = try launch()
        defer { app.terminate() }

        BattyCLI.runExpectingSuccess(["ping"])
        BattyCLI.runExpectingSuccess(["capabilities", "--json"])
        BattyScreen.expectMatches(initial, in: app)
    }

    // MARK: - new

    @MainActor
    func testNewCreatesSessionVisibleInSidebar() throws {
        let (app, _, initial) = try launch()
        defer { app.terminate() }

        let project = try makeDirectory("new-session-project")
        let result = BattyCLI.runExpectingSuccess(["new", project.path])
        XCTAssertEqual(result.ids.count, 2, "new must print a Session id then its focused Pane id: \(result.summary)")
        let sessionID = try XCTUnwrap(result.ids.first)
        let paneID = try XCTUnwrap(result.ids.last)

        let topology = try XCTUnwrap(BattyCLI.waitForTopology { $0.session(sessionID) != nil }, "the printed Session id is not in list --json")
        XCTAssertEqual(topology.sessions.count, initial.sessions.count + 1)
        let session = try XCTUnwrap(topology.session(sessionID))
        XCTAssertEqual(session.focusedPaneID, paneID, "the second printed id must be the Session's focused Pane")
        XCTAssertNotNil(session.pane(paneID))

        XCTAssertTrue(
            BattyUITestHarness.sessionRow(named: session.name, in: app).waitForExistence(timeout: 10),
            "no Sidebar row session-row.\(session.name) for the new Session"
        )
        BattyScreen.expectMatches(topology, in: app)

        let jsonProject = try makeDirectory("new-session-json-project")
        let json = BattyCLI.runExpectingSuccess(["new", "--json", jsonProject.path])
        let object = try XCTUnwrap(CLITopology.jsonObject(in: json.output), "new --json was not JSON: \(json.output)")
        let jsonSessionID = try XCTUnwrap((object["sessionID"] as? String).flatMap(UUID.init(uuidString:)))
        let jsonPaneID = try XCTUnwrap((object["paneID"] as? String).flatMap(UUID.init(uuidString:)))
        let after = try XCTUnwrap(BattyCLI.waitForTopology { $0.session(jsonSessionID) != nil })
        XCTAssertEqual(after.session(jsonSessionID)?.focusedPaneID, jsonPaneID)
        BattyScreen.expectMatches(after, in: app)
    }

    @MainActor
    func testNewNoWaitStillCreatesTheSession() throws {
        let (app, _, initial) = try launch()
        defer { app.terminate() }

        let project = try makeDirectory("no-wait-project")
        let result = BattyCLI.runExpectingSuccess(["new", "--no-wait", project.path])
        XCTAssertTrue(result.ids.isEmpty, "--no-wait exits before it can report ids: \(result.summary)")

        let known = Set(initial.sessions.map(\.id))
        let topology = try XCTUnwrap(
            BattyCLI.waitForTopology { $0.sessions.contains { !known.contains($0.id) } },
            "no new Session appeared after new --no-wait"
        )
        XCTAssertEqual(topology.sessions.count, initial.sessions.count + 1)
        BattyScreen.expectMatches(topology, in: app)
    }

    /// `new` immediately followed by a split of the Pane it returned, with
    /// nothing between: the returned Pane id must already be targetable.
    @MainActor
    func testSplitOfAPaneReturnedByNewNeedsNoWait() throws {
        let (app, _, _) = try launch()
        defer { app.terminate() }

        let project = try makeDirectory("rapid-project")
        let created = BattyCLI.runExpectingSuccess(["new", project.path])
        let sessionID = try XCTUnwrap(created.ids.first)
        let paneID = try XCTUnwrap(created.ids.last)

        let split = BattyCLI.runExpectingSuccess(["pane", "split", "--pane", paneID.uuidString])
        let newID = try XCTUnwrap(split.ids.last, "pane split printed no id: \(split.summary)")

        let topology = try XCTUnwrap(BattyCLI.waitForTopology { $0.session(sessionID)?.pane(newID) != nil })
        XCTAssertEqual(topology.session(sessionID)?.panes.count, 2)
        BattyScreen.expectMatches(topology, in: app)
    }

    // MARK: - pane split (terminal)

    @MainActor
    func testSplitHorizontalAndVerticalAddVisibleTerminalPanes() throws {
        let (app, _, initial) = try launch()
        defer { app.terminate() }

        let session = try XCTUnwrap(initial.selectedSession)
        let first = session.focusedPaneID
        let fullFrame = frame(ofTerminalPane: first, in: app)
        XCTAssertGreaterThan(fullFrame.width, 1)

        // --horizontal (the default direction) places the new Pane beside the
        // original, and `--command` runs in it instead of the default shell.
        let sentinel = BattyUITestHarness.sentinelPath(named: "split-command")
        let script = try BattyCLI.makeScript(in: scratch, named: "touch-sentinel.sh", body: "touch \(BattyCLI.shellQuoted(sentinel))")
        let second = try splitTerminal("-h", of: first, extra: ["--command", script])
        XCTAssertTrue(BattyUITestHarness.waitForFile(at: sentinel, timeout: 15), "--command did not run in the new Pane")

        let paneB = BattyScreen.terminalPane(second, in: app)
        XCTAssertTrue(paneB.waitForExistence(timeout: 10), "no pane-terminal.\(second) after pane split -h")
        XCTAssertTrue(waitFor({ self.frame(ofTerminalPane: first, in: app).width < fullFrame.width * 0.75 }, timeout: 10),
                      "the original Pane did not give up space to the split")
        let a1 = frame(ofTerminalPane: first, in: app)
        let b1 = paneB.frame
        XCTAssertGreaterThan(b1.width, 1)
        XCTAssertEqual(BattyScreen.overlapArea(a1, b1), 0, accuracy: 4, "split Panes overlap: \(a1) vs \(b1)")
        XCTAssertTrue(a1.maxX <= b1.minX + 4 || b1.maxX <= a1.minX + 4, "-h must place Panes side by side: \(a1) vs \(b1)")
        XCTAssertEqual(a1.minY, b1.minY, accuracy: 4)

        // --vertical of the new Pane stacks a third one.
        let third = try splitTerminal("-v", of: second)
        let paneC = BattyScreen.terminalPane(third, in: app)
        XCTAssertTrue(paneC.waitForExistence(timeout: 10), "no pane-terminal.\(third) after pane split -v")
        XCTAssertTrue(waitFor({ self.frame(ofTerminalPane: second, in: app).height < b1.height * 0.75 }, timeout: 10))
        let b2 = frame(ofTerminalPane: second, in: app)
        let c2 = paneC.frame
        XCTAssertEqual(BattyScreen.overlapArea(b2, c2), 0, accuracy: 4, "split Panes overlap: \(b2) vs \(c2)")
        XCTAssertTrue(b2.maxY <= c2.minY + 4 || c2.maxY <= b2.minY + 4, "-v must stack Panes: \(b2) vs \(c2)")
        XCTAssertEqual(b2.minX, c2.minX, accuracy: 4)

        let topology = try XCTUnwrap(BattyCLI.waitForTopology { $0.session(session.id)?.panes.count == 3 })
        XCTAssertEqual(Set(topology.session(session.id)?.panes.map(\.id) ?? []), [first, second, third])
        XCTAssertTrue(topology.session(session.id)?.panes.allSatisfy { $0.kind == "terminal" && !$0.isHidden } ?? false)
        BattyScreen.expectMatches(topology, in: app)
    }

    /// A burst of splits back to back, no waits between: every returned id
    /// must be a Pane on screen.
    @MainActor
    func testBurstOfSplitsAllLandOnScreen() throws {
        let (app, _, initial) = try launch()
        defer { app.terminate() }

        let session = try XCTUnwrap(initial.selectedSession)
        var ids: [UUID] = []
        for index in 0..<4 {
            let flag = index.isMultiple(of: 2) ? "-h" : "-v"
            ids.append(try splitTerminal(flag, of: ids.last ?? session.focusedPaneID))
        }
        XCTAssertEqual(Set(ids).count, 4, "a burst returned duplicate Pane ids")

        let topology = try XCTUnwrap(BattyCLI.waitForTopology { $0.session(session.id)?.panes.count == 5 })
        for id in ids {
            XCTAssertNotNil(topology.pane(id), "returned id \(id) is not in list --json")
            XCTAssertTrue(BattyScreen.terminalPane(id, in: app).waitForExistence(timeout: 10), "returned id \(id) is not on screen")
        }
        BattyScreen.expectMatches(topology, in: app)
    }

    // MARK: - pane hide / show / close

    @MainActor
    func testHideShowAndCloseChangeWhatIsOnScreen() throws {
        let (app, _, initial) = try launch()
        defer { app.terminate() }

        let session = try XCTUnwrap(initial.selectedSession)
        let first = session.focusedPaneID
        let fullFrame = frame(ofTerminalPane: first, in: app)
        let second = try splitTerminal("-h", of: first)
        XCTAssertTrue(BattyScreen.terminalPane(second, in: app).waitForExistence(timeout: 10))
        XCTAssertTrue(waitFor({ self.frame(ofTerminalPane: first, in: app).width < fullFrame.width * 0.75 }, timeout: 10))

        // hide: leaves the split, stays listed as hidden, the sibling takes over.
        BattyCLI.runExpectingSuccess(["pane", "hide", "--pane", second.uuidString])
        var topology = try XCTUnwrap(BattyCLI.waitForTopology { $0.pane(second)?.isHidden == true })
        XCTAssertEqual(topology.session(session.id)?.panes.count, 2, "a hidden Pane stays listed")
        BattyScreen.expectMatches(topology, in: app)
        XCTAssertTrue(waitFor({ self.frame(ofTerminalPane: first, in: app).width > fullFrame.width * 0.9 }, timeout: 10),
                      "the visible sibling did not take over the hidden Pane's space")

        // hide is idempotent.
        BattyCLI.runExpectingSuccess(["pane", "hide", "--pane", second.uuidString])

        // A Session's only visible Pane refuses to hide, and nothing changes.
        let refusedHide = BattyCLI.run(["pane", "hide", "--pane", first.uuidString])
        XCTAssertEqual(refusedHide.status, 4, "hiding the only visible Pane must exit 4: \(refusedHide.summary)")
        topology = try XCTUnwrap(BattyCLI.topology())
        XCTAssertEqual(topology.pane(first)?.isHidden, false)
        BattyScreen.expectMatches(topology, in: app)

        // show: the Pane returns with a non-zero frame and the space is shared again.
        BattyCLI.runExpectingSuccess(["pane", "show", second.uuidString])
        topology = try XCTUnwrap(BattyCLI.waitForTopology { $0.pane(second)?.isHidden == false })
        BattyScreen.expectMatches(topology, in: app)
        XCTAssertTrue(waitFor({ self.frame(ofTerminalPane: first, in: app).width < fullFrame.width * 0.75 }, timeout: 10))
        XCTAssertGreaterThan(frame(ofTerminalPane: second, in: app).width, 1)

        // close: the Pane's identifiers disappear and the sibling takes over.
        BattyCLI.runExpectingSuccess(["pane", "close", "--pane", second.uuidString])
        topology = try XCTUnwrap(BattyCLI.waitForTopology { $0.pane(second) == nil })
        XCTAssertEqual(topology.session(session.id)?.panes.count, 1)
        XCTAssertTrue(waitFor({ !BattyScreen.terminalPane(second, in: app).exists }, timeout: 10), "a closed Pane is still on screen")
        XCTAssertTrue(waitFor({ self.frame(ofTerminalPane: first, in: app).width > fullFrame.width * 0.9 }, timeout: 10))
        BattyScreen.expectMatches(topology, in: app)

        // The app's last Pane refuses to close, and nothing changes.
        let refusedClose = BattyCLI.run(["pane", "close", "--pane", first.uuidString])
        XCTAssertEqual(refusedClose.status, 4, "closing the app's last Pane must exit 4: \(refusedClose.summary)")
        topology = try XCTUnwrap(BattyCLI.topology())
        XCTAssertEqual(topology.session(session.id)?.panes.map(\.id), [first])
        BattyScreen.expectMatches(topology, in: app)
    }

    /// The Sidebar's pane row marks a hidden Pane. Separate from the test
    /// above because it depends on expanding the Session row's pane list
    /// (#0417 tracks that failing in the guest).
    @MainActor
    func testSidebarPaneRowShowsHiddenState() throws {
        let (app, _, initial) = try launch()
        defer { app.terminate() }

        let session = try XCTUnwrap(initial.selectedSession)
        let second = try splitTerminal("-h", of: session.focusedPaneID)
        BattyCLI.runExpectingSuccess(["pane", "hide", "--pane", second.uuidString])
        _ = try XCTUnwrap(BattyCLI.waitForTopology { $0.pane(second)?.isHidden == true })

        // Hiding auto-expands the Session's pane list (#0258), so no click is
        // needed; clicking the chevron here would collapse it again.
        let toggle = BattyScreen.element("pane-eye-toggle.\(second.uuidString)", in: app)
        XCTAssertTrue(toggle.waitForExistence(timeout: 10), "the hidden Pane has no Sidebar row")
        XCTAssertTrue(waitFor({ (toggle.value as? String) == "hidden" }, timeout: 10), "its eye toggle does not read hidden: \(String(describing: toggle.value))")

        BattyCLI.runExpectingSuccess(["pane", "show", second.uuidString])
        XCTAssertTrue(waitFor({ (toggle.value as? String) == "visible" }, timeout: 10), "its eye toggle does not read visible after show")
    }

    // MARK: - focus verbs

    @MainActor
    func testPaneFocusMovesTheFocusedPane() throws {
        let (app, _, initial) = try launch()
        defer { app.terminate() }

        let session = try XCTUnwrap(initial.selectedSession)
        let first = session.focusedPaneID
        let second = try splitTerminal("-h", of: first)
        XCTAssertTrue(BattyScreen.terminalPane(second, in: app).waitForExistence(timeout: 10))

        for target in [first, second, first] {
            BattyCLI.runExpectingSuccess(["pane", "focus", target.uuidString])
            let topology = try XCTUnwrap(BattyCLI.waitForTopology { $0.session(session.id)?.focusedPaneID == target })
            XCTAssertEqual(topology.pane(target)?.isFocused, true)
            let other = target == first ? second : first
            XCTAssertTrue(
                waitFor({
                    BattyScreen.terminalPane(target, in: app).label == "focused"
                        && BattyScreen.terminalPane(other, in: app).label == "unfocused"
                }, timeout: 10),
                "pane focus \(target) did not move the focused marker on screen"
            )
        }
    }

    @MainActor
    func testSessionFocusSelectsTheSessionRow() throws {
        let (app, _, initial) = try launch()
        defer { app.terminate() }

        let firstSession = try XCTUnwrap(initial.selectedSession)
        let project = try makeDirectory("focus-target-project")
        let created = BattyCLI.runExpectingSuccess(["new", project.path])
        let secondID = try XCTUnwrap(created.ids.first)
        let secondPaneID = try XCTUnwrap(created.ids.last)
        let topology = try XCTUnwrap(BattyCLI.waitForTopology { $0.session(secondID) != nil })
        let secondName = try XCTUnwrap(topology.session(secondID)?.name)

        func rowValue(_ name: String) -> String? { BattyUITestHarness.sessionRow(named: name, in: app).value as? String }

        for (target, targetName, otherName) in [(firstSession.id, firstSession.name, secondName), (secondID, secondName, firstSession.name)] {
            BattyCLI.runExpectingSuccess(["session", "focus", target.uuidString])
            let focused = try XCTUnwrap(BattyCLI.waitForTopology { $0.selectedSessionID == target })
            XCTAssertTrue(
                waitFor({ rowValue(targetName) == "selected" && rowValue(otherName) == "unselected" }, timeout: 10),
                "session focus did not move the Sidebar selection: \(targetName)=\(String(describing: rowValue(targetName))) \(otherName)=\(String(describing: rowValue(otherName)))"
            )
            BattyScreen.expectMatches(focused, in: app)
        }
        XCTAssertNotNil(topology.session(secondID)?.pane(secondPaneID))
    }

    /// `pane split` / `pane close` aimed at a background Session take effect
    /// there and do not switch the selected Session; the change shows once
    /// the Session is focused.
    @MainActor
    func testBackgroundSessionTargetsDoNotStealSelection() throws {
        let (app, _, initial) = try launch()
        defer { app.terminate() }

        let selected = try XCTUnwrap(initial.selectedSession)
        let project = try makeDirectory("background-project")
        let created = BattyCLI.runExpectingSuccess(["new", project.path])
        let backgroundID = try XCTUnwrap(created.ids.first)
        let backgroundPane = try XCTUnwrap(created.ids.last)
        _ = try XCTUnwrap(BattyCLI.waitForTopology { $0.session(backgroundID) != nil })
        BattyCLI.runExpectingSuccess(["session", "focus", selected.id.uuidString])
        _ = try XCTUnwrap(BattyCLI.waitForTopology { $0.selectedSessionID == selected.id })

        let split = try splitTerminal("-h", of: backgroundPane)
        var topology = try XCTUnwrap(BattyCLI.waitForTopology { $0.session(backgroundID)?.pane(split) != nil })
        XCTAssertEqual(topology.selectedSessionID, selected.id, "pane split in a background Session switched the selected Session")
        XCTAssertEqual(topology.session(selected.id)?.panes.count, selected.panes.count, "the split landed in the wrong Session")

        BattyCLI.runExpectingSuccess(["session", "focus", backgroundID.uuidString])
        topology = try XCTUnwrap(BattyCLI.waitForTopology { $0.selectedSessionID == backgroundID })
        BattyScreen.expectMatches(topology, in: app)
        XCTAssertTrue(BattyScreen.terminalPane(split, in: app).waitForExistence(timeout: 10), "the background split is not on screen after session focus")

        BattyCLI.runExpectingSuccess(["session", "focus", selected.id.uuidString])
        _ = try XCTUnwrap(BattyCLI.waitForTopology { $0.selectedSessionID == selected.id })
        BattyCLI.runExpectingSuccess(["pane", "close", "--pane", split.uuidString])
        topology = try XCTUnwrap(BattyCLI.waitForTopology { $0.pane(split) == nil })
        XCTAssertEqual(topology.selectedSessionID, selected.id, "pane close in a background Session switched the selected Session")
        BattyScreen.expectMatches(topology, in: app)
    }

    @MainActor
    func testTabFocusMovesTheActiveTabChip() throws {
        let (app, _, initial) = try launch()
        defer { app.terminate() }

        let session = try XCTUnwrap(initial.selectedSession)
        let pane = try XCTUnwrap(session.pane(session.focusedPaneID))
        let firstTab = pane.activeTabID

        app.typeKey("t", modifierFlags: [.command])
        let twoTabs = try XCTUnwrap(BattyCLI.waitForTopology { $0.pane(pane.id)?.tabIDs.count == 2 }, "Cmd-T did not add a Tab")
        let secondTab = try XCTUnwrap(twoTabs.pane(pane.id)?.tabIDs.first { $0 != firstTab })
        XCTAssertEqual(twoTabs.pane(pane.id)?.activeTabID, secondTab, "the new Tab should be active")

        struct Chip { let frame: CGRect; let value: String }
        func chips() -> [Chip] {
            BattyScreen.elements(withPrefix: "tab-chip.", in: app)
                .map { Chip(frame: $0.frame, value: $0.value as? String ?? "?") }
                .sorted { $0.frame.minX < $1.frame.minX }
        }
        // Both Tabs are titled "~", so their identifiers collide, and the
        // active chip's close button can surface under the chip's identifier
        // too. The chip for the first Tab is the leftmost match; an element
        // inside its frame is treated as that same chip, and an element
        // outside it (to the right) belongs to a later chip.
        func activeOutside(_ leftmost: Chip) -> Int {
            chips().filter { $0.value == "active" && !leftmost.frame.contains($0.frame) }.count
        }
        func diagnose(_ label: String) {
            let matched = BattyScreen.elements(withPrefix: "tab-chip.", in: app)
                .map { "type=\($0.elementType.rawValue) id=\($0.identifier) label=\($0.label) value=\($0.value as? String ?? "nil") frame=\($0.frame) hittable=\($0.isHittable)" }
            let bar = BattyScreen.elements(withPrefix: "tab-bar.\(pane.id.uuidString)", in: app).first?.debugDescription ?? "<no tab-bar element>"
            let attachment = XCTAttachment(string: "\(label)\n\(matched.joined(separator: "\n"))\n\n\(bar)\n\n\(app.debugDescription)")
            attachment.name = "tab-chip diagnostics: \(label)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }

        let settled = waitFor({
            guard let first = chips().first else { return false }
            return first.value == "inactive" && activeOutside(first) >= 1
        }, timeout: 10)
        if !settled { diagnose("after Cmd-T") }
        XCTAssertTrue(settled, "expected the first chip inactive with the active chip to its right, saw \(chips().map { "\($0.value)@\($0.frame)" })")

        BattyCLI.runExpectingSuccess(["tab", "focus", firstTab.uuidString])
        let refocused = try XCTUnwrap(BattyCLI.waitForTopology { $0.pane(pane.id)?.activeTabID == firstTab })
        XCTAssertEqual(refocused.pane(pane.id)?.tabIDs.first, firstTab)
        let flipped = waitFor({
            guard let first = chips().first else { return false }
            return first.value == "active" && activeOutside(first) == 0
        }, timeout: 10)
        if !flipped { diagnose("after tab focus") }
        XCTAssertTrue(flipped, "tab focus did not make the first chip the only active one: \(chips().map { "\($0.value)@\($0.frame)" })")
        BattyScreen.expectMatches(refocused, in: app)
    }

    // MARK: - session close

    @MainActor
    func testSessionCloseRemovesTheRowAndRefusesTheLastSession() throws {
        let (app, _, initial) = try launch()
        defer { app.terminate() }

        let original = try XCTUnwrap(initial.selectedSession)
        let project = try makeDirectory("close-project")
        let created = BattyCLI.runExpectingSuccess(["new", project.path])
        let extraID = try XCTUnwrap(created.ids.first)
        let withExtra = try XCTUnwrap(BattyCLI.waitForTopology { $0.session(extraID) != nil })
        let extraName = try XCTUnwrap(withExtra.session(extraID)?.name)
        XCTAssertTrue(BattyUITestHarness.sessionRow(named: extraName, in: app).waitForExistence(timeout: 10))

        BattyCLI.runExpectingSuccess(["session", "close", "--session", extraID.uuidString])
        let closed = try XCTUnwrap(BattyCLI.waitForTopology { $0.session(extraID) == nil })
        XCTAssertEqual(closed.sessions.map(\.id), [original.id])
        XCTAssertTrue(waitFor({ !BattyUITestHarness.sessionRow(named: extraName, in: app).exists }, timeout: 10), "the closed Session's Sidebar row is still on screen")
        BattyScreen.expectMatches(closed, in: app)

        let refused = BattyCLI.run(["session", "close", "--session", original.id.uuidString])
        XCTAssertEqual(refused.status, 4, "closing the app's last Session must exit 4: \(refused.summary)")
        let unchanged = try XCTUnwrap(BattyCLI.topology())
        XCTAssertEqual(unchanged.sessions.map(\.id), [original.id])
        BattyScreen.expectMatches(unchanged, in: app)
    }

    // MARK: - notify

    @MainActor
    func testNotifyPostsBellFeedEntries() throws {
        let (app, _, initial) = try launch()
        defer { app.terminate() }

        let session = try XCTUnwrap(initial.selectedSession)
        let tab = try XCTUnwrap(session.pane(session.focusedPaneID)?.activeTabID)

        func entryCount() -> Int { BattyScreen.identifiers(withPrefix: "bell-feed-entry.", in: app).count }
        let bell = app.toolbars.buttons["Bell Feed"].firstMatch
        XCTAssertTrue(bell.waitForExistence(timeout: 10), "no Bell Feed toolbar button")
        bell.click()
        XCTAssertTrue(
            waitFor({ app.popovers.firstMatch.exists || BattyScreen.element("bell-feed.list", in: app).exists || app.staticTexts["No bell events"].exists }, timeout: 10),
            "the Bell Feed did not open"
        )
        XCTAssertEqual(entryCount(), 0)

        BattyCLI.runExpectingSuccess(["notify", "--title", "first title", "--body", "first body", "--tab", tab.uuidString])
        XCTAssertTrue(waitFor({ entryCount() == 1 }, timeout: 10), "notify did not add a Bell Feed entry (\(entryCount()))")

        // An unknown Tab is refused and adds nothing. The valid notify that
        // follows is the barrier: requests are served in order, so once it
        // has landed, a wrongly added entry would already show as a third.
        let refused = BattyCLI.run(["notify", "--title", "ghost", "--tab", UUID().uuidString])
        XCTAssertEqual(refused.status, 4, "notify to an unknown Tab must exit 4: \(refused.summary)")
        BattyCLI.runExpectingSuccess(["notify", "--title", "second title", "--tab", tab.uuidString])
        XCTAssertTrue(waitFor({ entryCount() >= 2 }, timeout: 10))
        XCTAssertEqual(entryCount(), 2, "the refused notify must not add an entry")
    }

    // MARK: - bad targets

    @MainActor
    func testBadTargetsExitWithDocumentedCodesAndChangeNothing() throws {
        let (app, _, initial) = try launch()
        defer { app.terminate() }

        let session = try XCTUnwrap(initial.selectedSession)
        let unknown = UUID().uuidString

        let wellFormedUnknown: [[String]] = [
            ["pane", "split", "--pane", unknown],
            ["pane", "close", "--pane", unknown],
            ["pane", "focus", unknown],
            ["pane", "hide", "--pane", unknown],
            ["pane", "show", unknown],
            ["tab", "focus", unknown],
            ["session", "focus", unknown],
            ["session", "close", "--session", unknown],
            ["session", "info", "--session", unknown],
            ["notify", "--title", "ghost", "--tab", unknown],
        ]
        for arguments in wellFormedUnknown {
            let result = BattyCLI.run(arguments)
            XCTAssertEqual(result.status, 4, "batty \(arguments.joined(separator: " ")) with an unknown id must exit 4: \(result.summary)")
        }

        let malformed: [[String]] = [
            ["pane", "split", "--pane", "not-a-uuid"],
            ["pane", "close", "--pane", "not-a-uuid"],
            ["pane", "focus", "not-a-uuid"],
            ["pane", "hide", "--pane", "not-a-uuid"],
            ["pane", "show", "not-a-uuid"],
            ["tab", "focus", "not-a-uuid"],
            ["session", "focus", "not-a-uuid"],
            ["session", "close", "--session", "not-a-uuid"],
            ["session", "info", "--session", "not-a-uuid"],
            ["notify", "--title", "ghost", "--tab", "not-a-uuid"],
        ]
        for arguments in malformed {
            let result = BattyCLI.run(arguments)
            XCTAssertTrue([1, 64].contains(result.status), "batty \(arguments.joined(separator: " ")) with a malformed id must exit 1 or 64: \(result.summary)")
        }

        let invalidView = BattyCLI.run(["pane", "split", "--pane", session.focusedPaneID.uuidString, "--view", "nonsense"])
        XCTAssertTrue([1, 64].contains(invalidView.status), "an invalid --view must exit 1 or 64: \(invalidView.summary)")

        let unchanged = try XCTUnwrap(BattyCLI.topology())
        XCTAssertEqual(unchanged.sessions.map(\.id), initial.sessions.map(\.id))
        XCTAssertEqual(unchanged.session(session.id)?.panes.map(\.id), session.panes.map(\.id))
        BattyScreen.expectMatches(unchanged, in: app)
    }

    // MARK: - read verbs agree with the screen

    @MainActor
    func testStatusSessionInfoAndListAgreeWithTheScreen() throws {
        let (app, _, initial) = try launch()
        defer { app.terminate() }

        let session = try XCTUnwrap(initial.selectedSession)
        let second = try splitTerminal("-h", of: session.focusedPaneID)
        _ = try splitTerminal("-v", of: second)
        let project = try makeDirectory("agree-project")
        BattyCLI.runExpectingSuccess(["new", project.path])
        let topology = try XCTUnwrap(BattyCLI.waitForTopology { $0.sessions.count == initial.sessions.count + 1 && $0.session(session.id)?.panes.count == 3 })
        BattyScreen.expectMatches(topology, in: app)

        let statusResult = BattyCLI.runExpectingSuccess(["status", "--json"])
        let status = try XCTUnwrap(CLITopology.jsonObject(in: statusResult.output)?["status"] as? [String: Any])
        XCTAssertEqual(status["sessionCount"] as? Int, topology.sessions.count)
        let tabCount = topology.sessions.reduce(0) { $0 + $1.panes.reduce(0) { $0 + $1.tabIDs.count } }
        XCTAssertEqual(status["tabCount"] as? Int, tabCount)
        XCTAssertEqual(status["windowCount"] as? Int, 1)
        XCTAssertEqual(BattyScreen.identifiers(withPrefix: "session-row.", in: app).count, status["sessionCount"] as? Int)

        for expected in topology.sessions {
            let info = BattyCLI.runExpectingSuccess(["session", "info", "--session", expected.id.uuidString, "--json"])
            let decoded = try XCTUnwrap(CLITopology(sessionInfoOutput: info.output), "session info --json was not a Session: \(info.output)")
            let actual = try XCTUnwrap(decoded.sessions.first)
            XCTAssertEqual(actual.id, expected.id)
            XCTAssertEqual(actual.name, expected.name)
            XCTAssertEqual(actual.panes.map(\.id), expected.panes.map(\.id))
            XCTAssertEqual(actual.panes.map(\.isHidden), expected.panes.map(\.isHidden))
            XCTAssertEqual(actual.focusedPaneID, expected.focusedPaneID)
        }

        let plain = BattyCLI.runExpectingSuccess(["list", "panes"])
        for pane in topology.allPaneIDs {
            XCTAssertTrue(plain.output.contains(pane.uuidString), "list panes is missing \(pane)")
        }
    }

    /// Run with no `BATTY_*` environment (as the relay does), `id` has no
    /// Pane to report; run inside a Pane it reports that Pane's ids.
    @MainActor
    func testIDReportsThePaneItRunsIn() throws {
        let (app, appURL, initial) = try launch()
        defer { app.terminate() }

        let outside = BattyCLI.run(["id"])
        XCTAssertEqual(outside.status, 1, "id with no BATTY_* environment must exit 1: \(outside.summary)")

        let session = try XCTUnwrap(initial.selectedSession)
        let sentinel = BattyUITestHarness.sentinelPath(named: "id-json")
        let script = try BattyCLI.makeScript(
            in: scratch,
            named: "run-id.sh",
            body: "\(BattyCLI.shellQuoted(BattyCLI.embeddedCLIPath(in: appURL))) id --json > \(BattyCLI.shellQuoted(sentinel)) 2>&1"
        )
        let pane = try splitTerminal("-h", of: session.focusedPaneID, extra: ["--command", script])
        XCTAssertTrue(BattyUITestHarness.waitForFile(at: sentinel, timeout: 20), "the in-Pane command never wrote its output")
        let reported = try XCTUnwrap(
            waitForNonEmptyFile(sentinel).flatMap { CLITopology.jsonObject(in: $0) },
            "id --json inside a Pane was not JSON: \(BattyCLI.readTrimmed(sentinel) ?? "<unreadable>")"
        )
        XCTAssertEqual((reported["paneID"] as? String).flatMap(UUID.init(uuidString:)), pane)
        XCTAssertEqual((reported["sessionID"] as? String).flatMap(UUID.init(uuidString:)), session.id)
    }

    private func waitForNonEmptyFile(_ path: String) -> String? {
        var text: String?
        BattyUITestHarness.waitFor({
            guard let contents = BattyCLI.readTrimmed(path), contents.contains("}") else { return false }
            text = contents
            return true
        }, timeout: 15)
        return text
    }
}
