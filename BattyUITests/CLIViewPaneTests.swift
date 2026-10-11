// CLIViewPaneTests.swift

import XCTest

/// `batty pane split --view <kind>` against the real app (#0413), asserting
/// that each non-terminal view renders in a new visible Pane. #0333 is the
/// cautionary case: the verb exited 0 and `list --json` showed the right
/// topology while the window still showed one terminal Pane. A Pane's
/// content views are not keyed by Pane id, so each is tied to the id the CLI
/// returned through that Pane's id-keyed header (`pane-close-button.<id>`).
nonisolated final class CLIViewPaneTests: XCTestCase {
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
    private func launch() throws -> (app: XCUIApplication, appURL: URL, session: CLITopology.Session) {
        let app = BattyUITestHarness.launchBatty()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10), "Batty did not open a window")
        let (appURL, initial) = try BattyCLI.connect(to: app, from: CLIViewPaneTests.self)
        let session = try XCTUnwrap(initial.selectedSession)
        return (app, appURL, session)
    }

    /// Splits `source` with `--view kind`, then asserts the new Pane is a
    /// visible, id-keyed Pane of that kind whose content is on screen beside
    /// (not over) the source terminal Pane. Returns the new Pane's id and its
    /// content element.
    @MainActor
    @discardableResult
    private func splitViewAndAssertRendered(
        kind: String,
        contentIdentifier: String,
        extraArguments: [String] = [],
        source: UUID,
        in session: CLITopology.Session,
        app: XCUIApplication,
        contentTimeout: TimeInterval = 15,
        contentSpansColumn: Bool = true
    ) throws -> (id: UUID, content: XCUIElement) {
        let sourceFrameBefore = BattyScreen.terminalPane(source, in: app).frame
        XCTAssertGreaterThan(BattyScreen.area(sourceFrameBefore), 0)

        let result = BattyCLI.runExpectingSuccess(["pane", "split", "--view", kind, "--pane", source.uuidString] + extraArguments)
        let id = try XCTUnwrap(result.ids.last, "pane split --view \(kind) printed no id: \(result.summary)")

        let topology = try XCTUnwrap(BattyCLI.waitForTopology { $0.session(session.id)?.pane(id) != nil }, "\(id) is not in list --json")
        let pane = try XCTUnwrap(topology.pane(id))
        XCTAssertEqual(pane.kind, kind)
        XCTAssertFalse(pane.isHidden)
        XCTAssertEqual(topology.session(session.id)?.panes.count, session.panes.count + 1)

        let close = BattyScreen.element("pane-close-button.\(id.uuidString)", in: app)
        XCTAssertTrue(close.waitForExistence(timeout: 10), "no header for the new \(kind) Pane (pane-close-button.\(id))")
        XCTAssertGreaterThan(BattyScreen.area(close.frame), 0)

        let content = BattyScreen.element(contentIdentifier, in: app)
        XCTAssertTrue(content.waitForExistence(timeout: contentTimeout), "\(contentIdentifier) never appeared for the \(kind) Pane")
        XCTAssertFalse(BattyScreen.element("pane-placeholder.\(kind)", in: app).exists, "the \(kind) Pane shows the provisional placeholder")

        // The content sits in this Pane: under its header, spanning its column.
        let contentFrame = content.frame
        XCTAssertGreaterThan(BattyScreen.area(contentFrame), 0, "\(contentIdentifier) has an empty frame")
        XCTAssertGreaterThanOrEqual(contentFrame.minY, close.frame.maxY - 2, "content is not below its Pane's header")
        if contentSpansColumn {
            XCTAssertLessThanOrEqual(contentFrame.minX, close.frame.midX)
            XCTAssertGreaterThanOrEqual(contentFrame.maxX, close.frame.midX)
        }

        // #0333: the source terminal Pane must have given up space and must
        // not sit under the new content.
        XCTAssertTrue(
            waitFor({ BattyScreen.area(BattyScreen.terminalPane(source, in: app).frame) < BattyScreen.area(sourceFrameBefore) * 0.8 }, timeout: 10),
            "the source terminal Pane still fills the content area (#0333)"
        )
        let sourceFrameAfter = BattyScreen.terminalPane(source, in: app).frame
        XCTAssertEqual(BattyScreen.overlapArea(sourceFrameAfter, contentFrame), 0, accuracy: 4, "\(kind) content overlaps the source Pane: \(contentFrame) vs \(sourceFrameAfter)")

        BattyScreen.expectMatches(topology, in: app)
        return (id, content)
    }

    // MARK: - One test per kind

    @MainActor
    func testSplitGitStatusRendersTheFixtureRepository() throws {
        let (app, _, session) = try launch()
        defer { app.terminate() }

        let repo = try BattyCLI.makeGitRepository(in: scratch)
        try splitViewAndAssertRendered(
            kind: "git-status",
            contentIdentifier: "git-status.snapshot",
            extraArguments: ["--path", repo.path],
            source: session.focusedPaneID,
            in: session,
            app: app
        )
        XCTAssertFalse(BattyScreen.element("git-status.not-a-repo", in: app).exists)
        XCTAssertFalse(BattyScreen.element("git-status.scan-failed", in: app).exists)
        // The fixture's one untracked file is the only proof the Pane scanned
        // --path rather than the source Pane's working directory (a plain
        // temp directory). Its row sits inside the collapsed "Untracked Files"
        // disclosure, so the group's count is what is visible.
        let untracked = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Untracked Files (1)")).firstMatch
        XCTAssertTrue(untracked.waitForExistence(timeout: 15), "the Pane did not report the fixture repository's one untracked file")
    }

    /// A Git Status Pane opened on a directory that is not a repository shows
    /// the not-a-repository state instead of a snapshot. The source Pane's
    /// working directory is a repository, so the state can only come from
    /// `--path`.
    @MainActor
    func testSplitGitStatusWithNonRepositoryPathShowsNotARepository() throws {
        let (app, _, _) = try launch()
        defer { app.terminate() }

        let repo = try BattyCLI.makeGitRepository(in: scratch)
        let (created, source) = try BattyCLI.newSession(at: repo)
        BattyCLI.runExpectingSuccess(["session", "focus", created.id.uuidString])
        let session = try XCTUnwrap(BattyCLI.waitForTopology { $0.selectedSessionID == created.id }?.session(created.id))
        XCTAssertTrue(BattyScreen.terminalPane(source, in: app).waitForExistence(timeout: 10))
        let fullFrame = BattyScreen.terminalPane(source, in: app).frame

        // Precondition: with no --path the Pane follows the source Pane's
        // repository, so a not-a-repo result below cannot be the default.
        let (defaultID, _) = try splitViewAndAssertRendered(
            kind: "git-status",
            contentIdentifier: "git-status.snapshot",
            source: source,
            in: session,
            app: app
        )
        BattyCLI.runExpectingSuccess(["pane", "close", "--pane", defaultID.uuidString])
        let afterClose = try XCTUnwrap(BattyCLI.waitForTopology { $0.pane(defaultID) == nil }?.session(created.id))
        XCTAssertTrue(waitFor({ BattyScreen.area(BattyScreen.terminalPane(source, in: app).frame) > BattyScreen.area(fullFrame) * 0.9 }, timeout: 10))

        let plain = scratch.appending(path: "plain-directory")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        try splitViewAndAssertRendered(
            kind: "git-status",
            contentIdentifier: "git-status.not-a-repo",
            extraArguments: ["--path", plain.path],
            source: source,
            in: afterClose,
            app: app,
            contentSpansColumn: false
        )
        XCTAssertFalse(BattyScreen.element("git-status.snapshot", in: app).exists)
    }

    @MainActor
    func testSplitProcessStatusRenders() throws {
        let (app, _, session) = try launch()
        defer { app.terminate() }

        try splitViewAndAssertRendered(
            kind: "process-status",
            contentIdentifier: "process-status-view",
            source: session.focusedPaneID,
            in: session,
            app: app
        )
    }

    /// `--pid` reaches the view: the header names the pinned pid and the run
    /// state chip reads running. Without `--pid` the view follows the source
    /// Pane's process instead, so the pid below cannot be the default.
    @MainActor
    func testSplitProcessStatusPinsThePid() throws {
        let (app, appURL, session) = try launch()
        defer { app.terminate() }

        let appPID = try XCTUnwrap(BattyCLI.launchedProcessID(of: appURL))
        let source = session.focusedPaneID
        let fullFrame = BattyScreen.terminalPane(source, in: app).frame
        let (followingID, _) = try splitViewAndAssertRendered(
            kind: "process-status",
            contentIdentifier: "process-status-view",
            source: source,
            in: session,
            app: app
        )
        let pid = BattyScreen.element("process-status.pid", in: app)
        XCTAssertTrue(pid.waitForExistence(timeout: 15), "the unpinned view shows no pid")
        XCTAssertNotEqual(pid.value as? String, String(appPID), "the unpinned view must not already show the app's pid")
        BattyCLI.runExpectingSuccess(["pane", "close", "--pane", followingID.uuidString])
        let afterClose = try XCTUnwrap(BattyCLI.waitForTopology { $0.pane(followingID) == nil }?.session(session.id))
        XCTAssertTrue(waitFor({ BattyScreen.area(BattyScreen.terminalPane(source, in: app).frame) > BattyScreen.area(fullFrame) * 0.9 }, timeout: 10))

        try splitViewAndAssertRendered(
            kind: "process-status",
            contentIdentifier: "process-status-view",
            extraArguments: ["--pid", String(appPID)],
            source: source,
            in: afterClose,
            app: app
        )
        XCTAssertTrue(
            waitFor({ (BattyScreen.element("process-status.pid", in: app).value as? String) == String(appPID) }, timeout: 15),
            "the view did not pin pid \(appPID): \(String(describing: BattyScreen.element("process-status.pid", in: app).value))"
        )
        XCTAssertTrue(
            waitFor({ (BattyScreen.element("process-status.state-chip", in: app).value as? String) == "running" }, timeout: 15),
            "the pinned live process should read running"
        )
        XCTAssertFalse(BattyScreen.element("process-status.exited-banner", in: app).exists)
        XCTAssertFalse(BattyScreen.element("process-status.no-selection", in: app).exists)
    }

    /// A pinned pid that has already exited reads exited, with the banner.
    @MainActor
    func testSplitProcessStatusWithExitedPidReadsExited() throws {
        let (app, _, session) = try launch()
        defer { app.terminate() }

        let finished = Process()
        finished.executableURL = URL(filePath: "/usr/bin/true")
        try finished.run()
        finished.waitUntilExit()
        let deadPID = finished.processIdentifier

        try splitViewAndAssertRendered(
            kind: "process-status",
            contentIdentifier: "process-status-view",
            extraArguments: ["--pid", String(deadPID)],
            source: session.focusedPaneID,
            in: session,
            app: app
        )
        XCTAssertTrue(
            waitFor({ (BattyScreen.element("process-status.state-chip", in: app).value as? String) == "exited" }, timeout: 15),
            "an exited pid must read exited, saw \(String(describing: BattyScreen.element("process-status.state-chip", in: app).value))"
        )
        XCTAssertTrue(BattyScreen.element("process-status.exited-banner", in: app).waitForExistence(timeout: 10))
    }

    @MainActor
    func testSplitSystemMetricsRendersLiveSamples() throws {
        let (app, _, session) = try launch()
        defer { app.terminate() }

        try splitViewAndAssertRendered(
            kind: "system-metrics",
            contentIdentifier: "system-metrics-pane",
            source: session.focusedPaneID,
            in: session,
            app: app
        )
        // The first-sample gate hides the refresh button until a real sample lands.
        XCTAssertTrue(
            BattyScreen.element("system-metrics-refresh-button", in: app).waitForExistence(timeout: 20),
            "system metrics never produced a first sample"
        )
    }

    /// The guest has no LM Studio server: the Pane and its disconnected
    /// state must render, not live data.
    @MainActor
    func testSplitLMStudioDashboardRendersDisconnected() throws {
        let (app, _, session) = try launch()
        defer { app.terminate() }

        try splitViewAndAssertRendered(
            kind: "lm-studio-dashboard",
            contentIdentifier: "lmstudio-dashboard",
            source: session.focusedPaneID,
            in: session,
            app: app
        )
        let pill = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'lmstudio-connection-pill.'")).firstMatch
        XCTAssertTrue(pill.waitForExistence(timeout: 10), "the dashboard shows no connection state")
        XCTAssertNotEqual(pill.identifier, "lmstudio-connection-pill.connected", "no LM Studio server exists in the guest")
    }

    // MARK: - Flag validation (client side, nothing changes)

    @MainActor
    func testInvalidViewFlagCombinationsAreRefusedAndChangeNothing() throws {
        let (app, _, session) = try launch()
        defer { app.terminate() }

        let pane = session.focusedPaneID.uuidString
        let refused: [[String]] = [
            ["pane", "split", "--pane", pane, "--unique"],
            ["pane", "split", "--pane", pane, "--view", "git-status", "--command", "true"],
            ["pane", "split", "--pane", pane, "--view", "git-status", "--pid", "1"],
            ["pane", "split", "--pane", pane, "--view", "process-status", "--path", scratch.path],
            ["pane", "split", "--pane", pane, "--view", "process-status", "--pid", "0"],
        ]
        for arguments in refused {
            let result = BattyCLI.run(arguments)
            XCTAssertNotEqual(result.status, 0, "batty \(arguments.joined(separator: " ")) must be refused: \(result.summary)")
            XCTAssertLessThan(result.status, 5, "batty \(arguments.joined(separator: " ")) should fail client side: \(result.summary)")
        }
        let unchanged = try XCTUnwrap(BattyCLI.topology())
        XCTAssertEqual(unchanged.session(session.id)?.panes.count, session.panes.count)
        BattyScreen.expectMatches(unchanged, in: app)
    }

    // MARK: - --unique

    /// Run from the test process: the first call creates the Pane, the second
    /// returns the same id and creates nothing, on screen as in `list`.
    @MainActor
    func testUniqueReusesTheSameGitStatusPane() throws {
        let (app, _, session) = try launch()
        defer { app.terminate() }

        let repo = try BattyCLI.makeGitRepository(in: scratch)
        let source = session.focusedPaneID
        let (id, _) = try splitViewAndAssertRendered(
            kind: "git-status",
            contentIdentifier: "git-status.snapshot",
            extraArguments: ["--unique", "--path", repo.path],
            source: source,
            in: session,
            app: app
        )

        let again = BattyCLI.runExpectingSuccess(["pane", "split", "--view", "git-status", "--unique", "--pane", source.uuidString])
        XCTAssertEqual(again.ids.last, id, "--unique must return the existing Pane's id: \(again.summary)")
        XCTAssertTrue(again.output.contains("--unique matched an existing pane"), "--unique did not report a match: \(again.output)")

        let topology = try XCTUnwrap(BattyCLI.topology())
        XCTAssertEqual(topology.session(session.id)?.panes.filter { $0.kind == "git-status" }.map(\.id), [id])
        XCTAssertEqual(topology.session(session.id)?.panes.count, session.panes.count + 1)
        XCTAssertEqual(BattyScreen.identifiers(withPrefix: "pane-close-button.", in: app), ["pane-close-button.\(id.uuidString)"],
                       "a second non-terminal Pane appeared")
        XCTAssertEqual(BattyScreen.identifiers(withPrefix: "git-status.snapshot", in: app).count, 1)
        BattyScreen.expectMatches(topology, in: app)
    }

    /// SKILL.md section 4: a hidden Pane of the kind is not a match, so
    /// `--unique` creates a new one; and a match never moves focus.
    @MainActor
    func testUniqueIgnoresHiddenPanesAndNeverMovesFocus() throws {
        let (app, _, session) = try launch()
        defer { app.terminate() }

        let repo = try BattyCLI.makeGitRepository(in: scratch)
        let source = session.focusedPaneID
        let (hiddenID, _) = try splitViewAndAssertRendered(
            kind: "git-status",
            contentIdentifier: "git-status.snapshot",
            extraArguments: ["--unique", "--path", repo.path],
            source: source,
            in: session,
            app: app
        )
        BattyCLI.runExpectingSuccess(["pane", "hide", "--pane", hiddenID.uuidString])
        _ = try XCTUnwrap(BattyCLI.waitForTopology { $0.pane(hiddenID)?.isHidden == true })

        let created = BattyCLI.runExpectingSuccess(["pane", "split", "--view", "git-status", "--unique", "--path", repo.path, "--pane", source.uuidString])
        let freshID = try XCTUnwrap(created.ids.last, "--unique printed no id: \(created.summary)")
        XCTAssertNotEqual(freshID, hiddenID, "a hidden Pane must not satisfy --unique")
        XCTAssertFalse(created.output.contains("--unique matched an existing pane"), created.output)
        var topology = try XCTUnwrap(BattyCLI.waitForTopology { $0.pane(freshID) != nil })
        XCTAssertEqual(Set(topology.session(session.id)?.panes.filter { $0.kind == "git-status" }.map(\.id) ?? []), [hiddenID, freshID])
        XCTAssertEqual(topology.pane(hiddenID)?.isHidden, true)
        XCTAssertEqual(topology.pane(freshID)?.isHidden, false)
        XCTAssertTrue(BattyScreen.element("pane-close-button.\(freshID.uuidString)", in: app).waitForExistence(timeout: 10))
        XCTAssertFalse(BattyScreen.element("pane-close-button.\(hiddenID.uuidString)", in: app).exists)

        // Focus the source Pane, then match: focus must stay on the source
        // rather than move to the matched Pane.
        BattyCLI.runExpectingSuccess(["pane", "focus", source.uuidString])
        _ = try XCTUnwrap(BattyCLI.waitForTopology { $0.session(session.id)?.focusedPaneID == source })
        let matched = BattyCLI.runExpectingSuccess(["pane", "split", "--view", "git-status", "--unique", "--pane", source.uuidString])
        XCTAssertEqual(matched.ids.last, freshID, "--unique must match the visible Pane: \(matched.summary)")
        XCTAssertTrue(matched.output.contains("--unique matched an existing pane"), matched.output)
        topology = try XCTUnwrap(BattyCLI.topology())
        XCTAssertEqual(topology.session(session.id)?.focusedPaneID, source, "a --unique match moved focus")
        XCTAssertEqual(topology.session(session.id)?.panes.count, session.panes.count + 2, "a match must create nothing")
        XCTAssertTrue(waitFor({ BattyScreen.terminalPane(source, in: app).label == "focused" }, timeout: 10))
        BattyScreen.expectMatches(topology, in: app)
    }

    /// The headline agent scenario: an agent inside a Pane opens a git view
    /// with `pane split --view git-status --unique`, and running it twice
    /// reuses the same Pane. The CLI runs inside a Terminal Session, so it
    /// carries that Pane's `BATTY_*` environment and no explicit target.
    @MainActor
    func testAgentInsideAPaneOpensGitStatusUniquelyTwice() throws {
        let (app, appURL, session) = try launch()
        defer { app.terminate() }

        let repo = try BattyCLI.makeGitRepository(in: scratch)
        let cli = BattyCLI.shellQuoted(BattyCLI.embeddedCLIPath(in: appURL))
        let first = BattyUITestHarness.sentinelPath(named: "unique-first")
        let second = BattyUITestHarness.sentinelPath(named: "unique-second")
        let done = BattyUITestHarness.sentinelPath(named: "unique-done")
        let script = try BattyCLI.makeScript(
            in: scratch,
            named: "agent.sh",
            body: """
            \(cli) pane split --view git-status --unique --path \(BattyCLI.shellQuoted(repo.path)) > \(BattyCLI.shellQuoted(first)) 2> \(BattyCLI.shellQuoted(first + ".err"))
            \(cli) pane split --view git-status --unique > \(BattyCLI.shellQuoted(second)) 2> \(BattyCLI.shellQuoted(second + ".err"))
            touch \(BattyCLI.shellQuoted(done))
            """
        )
        let agentPane = try XCTUnwrap(
            BattyCLI.runExpectingSuccess(["pane", "split", "--pane", session.focusedPaneID.uuidString, "--command", script]).ids.last
        )
        XCTAssertTrue(BattyUITestHarness.waitForFile(at: done, timeout: 30), "the in-Pane agent script never finished")

        let firstID = try XCTUnwrap(UUID(uuidString: BattyCLI.readTrimmed(first)?.split(separator: "\n").last.map(String.init) ?? ""), "first call printed: \(BattyCLI.readTrimmed(first) ?? "<unreadable>")")
        let secondOutput = BattyCLI.readTrimmed(second) ?? ""
        let secondDiagnostics = BattyCLI.readTrimmed(second + ".err") ?? ""
        let secondID = try XCTUnwrap(UUID(uuidString: secondOutput.split(separator: "\n").last.map(String.init) ?? ""), "second call printed: \(secondOutput)")
        XCTAssertEqual(firstID, secondID, "the second --unique call opened another Pane")
        XCTAssertTrue(secondDiagnostics.contains("--unique matched an existing pane"), "the second call did not report a match on stderr: \(secondDiagnostics)")

        let topology = try XCTUnwrap(BattyCLI.waitForTopology { $0.pane(firstID) != nil })
        let panes = try XCTUnwrap(topology.session(containing: agentPane)?.panes)
        XCTAssertEqual(panes.filter { $0.kind == "git-status" }.map(\.id), [firstID])
        XCTAssertEqual(panes.count, session.panes.count + 2, "expected the original Pane, the agent's Pane and one git-status Pane")

        XCTAssertTrue(BattyScreen.element("git-status.snapshot", in: app).waitForExistence(timeout: 15), "the git view is not on screen")
        XCTAssertEqual(BattyScreen.identifiers(withPrefix: "git-status.snapshot", in: app).count, 1)
        XCTAssertEqual(BattyScreen.identifiers(withPrefix: "pane-close-button.", in: app), ["pane-close-button.\(firstID.uuidString)"])
        BattyScreen.expectMatches(topology, in: app)
    }

    // MARK: - Hide, show and close a view Pane

    @MainActor
    func testHideShowAndCloseOnAViewPane() throws {
        let (app, _, session) = try launch()
        defer { app.terminate() }

        let source = session.focusedPaneID
        let sourceFull = BattyScreen.terminalPane(source, in: app).frame
        let (id, content) = try splitViewAndAssertRendered(
            kind: "system-metrics",
            contentIdentifier: "system-metrics-pane",
            source: source,
            in: session,
            app: app
        )

        BattyCLI.runExpectingSuccess(["pane", "hide", "--pane", id.uuidString])
        var topology = try XCTUnwrap(BattyCLI.waitForTopology { $0.pane(id)?.isHidden == true })
        XCTAssertTrue(waitFor({ !BattyScreen.element("pane-close-button.\(id.uuidString)", in: app).exists && !content.exists }, timeout: 10),
                      "a hidden view Pane is still on screen")
        XCTAssertTrue(waitFor({ BattyScreen.terminalPane(source, in: app).frame.width > sourceFull.width * 0.9 }, timeout: 10))
        BattyScreen.expectMatches(topology, in: app)

        BattyCLI.runExpectingSuccess(["pane", "show", id.uuidString])
        topology = try XCTUnwrap(BattyCLI.waitForTopology { $0.pane(id)?.isHidden == false })
        XCTAssertTrue(BattyScreen.element("pane-close-button.\(id.uuidString)", in: app).waitForExistence(timeout: 10))
        XCTAssertTrue(BattyScreen.element("system-metrics-pane", in: app).waitForExistence(timeout: 10))
        BattyScreen.expectMatches(topology, in: app)

        BattyCLI.runExpectingSuccess(["pane", "close", "--pane", id.uuidString])
        topology = try XCTUnwrap(BattyCLI.waitForTopology { $0.pane(id) == nil })
        XCTAssertTrue(waitFor({ !BattyScreen.element("pane-close-button.\(id.uuidString)", in: app).exists }, timeout: 10))
        XCTAssertFalse(BattyScreen.element("system-metrics-pane", in: app).exists, "closing the Pane left its content on screen")
        XCTAssertTrue(waitFor({ BattyScreen.terminalPane(source, in: app).frame.width > sourceFull.width * 0.9 }, timeout: 10))
        BattyScreen.expectMatches(topology, in: app)
    }

    /// `pane focus` on a view Pane moves focus in the model; the terminal
    /// Pane's focus marker follows.
    @MainActor
    func testFocusMovesBetweenTerminalAndViewPane() throws {
        let (app, _, session) = try launch()
        defer { app.terminate() }

        let source = session.focusedPaneID
        let (id, _) = try splitViewAndAssertRendered(
            kind: "process-status",
            contentIdentifier: "process-status-view",
            source: source,
            in: session,
            app: app
        )

        BattyCLI.runExpectingSuccess(["pane", "focus", id.uuidString])
        var topology = try XCTUnwrap(BattyCLI.waitForTopology { $0.session(session.id)?.focusedPaneID == id })
        XCTAssertTrue(waitFor({ BattyScreen.terminalPane(source, in: app).label == "unfocused" }, timeout: 10), "the terminal Pane still reads focused")
        BattyScreen.expectMatches(topology, in: app)

        BattyCLI.runExpectingSuccess(["pane", "focus", source.uuidString])
        topology = try XCTUnwrap(BattyCLI.waitForTopology { $0.session(session.id)?.focusedPaneID == source })
        XCTAssertTrue(waitFor({ BattyScreen.terminalPane(source, in: app).label == "focused" }, timeout: 10))
    }

    // MARK: - Reliability

    /// Twenty split/close rounds mixing terminal and non-terminal kinds: the
    /// topology and the screen end where they started, with nothing leaked.
    @MainActor
    func testRepeatedSplitCloseCyclesLeaveNothingBehind() throws {
        let (app, _, session) = try launch()
        defer { app.terminate() }

        let source = session.focusedPaneID
        let repo = try BattyCLI.makeGitRepository(in: scratch)
        let rounds: [[String]] = [
            [],
            ["--view", "git-status", "--path", repo.path],
            ["--view", "system-metrics"],
            ["--view", "process-status"],
            ["--view", "lm-studio-dashboard"],
        ]
        var seen: Set<UUID> = []
        for round in 0..<20 {
            let extra = rounds[round % rounds.count]
            let split = BattyCLI.runExpectingSuccess(["pane", "split", "--pane", source.uuidString] + extra)
            let id = try XCTUnwrap(split.ids.last, "round \(round): no id: \(split.summary)")
            XCTAssertTrue(seen.insert(id).inserted, "round \(round): id \(id) was handed out twice")
            let close = BattyCLI.run(["pane", "close", "--pane", id.uuidString])
            XCTAssertEqual(close.status, 0, "round \(round): close \(close.summary)")
        }

        let topology = try XCTUnwrap(BattyCLI.waitForTopology { $0.session(session.id)?.panes.map(\.id) == [source] }, "Panes were leaked in list --json")
        XCTAssertEqual(topology.allPaneIDs, [source])
        XCTAssertTrue(waitFor({ BattyScreen.identifiers(withPrefix: "pane-close-button.", in: app).isEmpty }, timeout: 10), "a view Pane is still on screen")
        XCTAssertEqual(BattyScreen.identifiers(withPrefix: "pane-terminal.", in: app), ["pane-terminal.\(source.uuidString)"], "a terminal Pane leaked onto the screen")
        BattyScreen.expectMatches(topology, in: app)
    }
}
