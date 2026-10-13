// GitStatusWorktreeTests.swift

import XCTest

/// The Git Status Pane's Worktrees group (#0488). The repositories are built by
/// a script run inside a terminal Pane (`pane split --command`) and a sentinel
/// the test waits for, because the sandboxed runner cannot run `git` itself
/// (`BattyCLI.makeGitRepository`).
nonisolated final class GitStatusWorktreeTests: XCTestCase {
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

    private struct Fixture {
        let main: String
        let branchWorktree: String
        let detachedWorktree: String
        let fourthWorktree: String
    }

    @MainActor
    private func launch() throws -> (app: XCUIApplication, session: CLITopology.Session) {
        let app = BattyUITestHarness.launchBatty()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10), "Batty did not open a window")
        let (_, initial) = try BattyCLI.connect(to: app, from: GitStatusWorktreeTests.self)
        let session = try XCTUnwrap(initial.selectedSession)
        return (app, session)
    }

    @MainActor
    private func runScript(_ body: String, named name: String, source: UUID) throws -> UUID {
        let command = try BattyCLI.makeScript(in: scratch, named: name, body: body)
        let result = BattyCLI.runExpectingSuccess(["pane", "split", "--pane", source.uuidString, "--command", command])
        return try XCTUnwrap(result.ids.last, "script pane printed no id: \(result.summary)")
    }

    /// A main repository with one commit plus a linked worktree on a branch and
    /// a detached one in a directory whose name contains a space.
    @MainActor
    private func buildFixture(source: UUID) throws -> Fixture {
        let q = BattyCLI.shellQuoted
        let fixture = Fixture(
            main: scratch.path + "/wt-main",
            branchWorktree: scratch.path + "/wt-branch",
            detachedWorktree: scratch.path + "/wt detached",
            fourthWorktree: scratch.path + "/wt-fourth"
        )
        let done = BattyUITestHarness.sentinelPath(named: "worktree-fixture-done")
        let body = """
        set -e
        export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
        export GIT_AUTHOR_NAME='Ada Lovelace' GIT_AUTHOR_EMAIL=ada@example.com
        export GIT_COMMITTER_NAME='Ada Lovelace' GIT_COMMITTER_EMAIL=ada@example.com
        rm -rf \(q(fixture.main)) \(q(fixture.branchWorktree)) \(q(fixture.detachedWorktree)) \(q(fixture.fourthWorktree))
        git init -q -b main \(q(fixture.main))
        cd \(q(fixture.main))
        printf 'one\\n' > a.txt
        git add -A
        git commit -q -m 'Base'
        git worktree add -q -b wt-branch-name \(q(fixture.branchWorktree))
        git worktree add -q --detach \(q(fixture.detachedWorktree))
        touch \(q(done))
        exec sleep 3600
        """
        let pane = try runScript(body, named: "worktree-fixture.sh", source: source)
        XCTAssertTrue(BattyUITestHarness.waitForFile(at: done, timeout: 90), "the worktree fixture script never finished")
        BattyCLI.runExpectingSuccess(["pane", "close", "--pane", pane.uuidString])
        return fixture
    }

    @MainActor
    private func openGitStatus(path: String, source: UUID, expectingPaneCount count: Int, in app: XCUIApplication) throws {
        let result = BattyCLI.runExpectingSuccess(["pane", "split", "--view", "git-status", "--path", path, "--pane", source.uuidString])
        XCTAssertNotNil(result.ids.last, "pane split --view git-status printed no id: \(result.summary)")
        XCTAssertTrue(
            waitFor({ BattyScreen.elements(withPrefix: "git-status.snapshot", in: app).count >= count }, timeout: 30),
            "expected \(count) git-status snapshot(s)"
        )
    }

    @MainActor
    private func worktreesGroup(in app: XCUIApplication) -> XCUIElement {
        app.disclosureTriangles.matching(NSPredicate(format: "label BEGINSWITH 'Worktrees ('")).firstMatch
    }

    @MainActor
    private func worktreeRows(_ basename: String, in app: XCUIApplication) -> [XCUIElement] {
        BattyScreen.elements(withPrefix: "git-status.worktree.\(basename)", in: app)
            .filter { $0.identifier == "git-status.worktree.\(basename)" }
    }

    /// The disclosure's frame spans its whole label and `click()` on the centre
    /// hits the label text, which does not toggle on macOS; the arrow sits near
    /// the leading edge (`ViewGalleryTests.expandDisclosures`).
    @MainActor
    private func expand(_ group: XCUIElement, expectingRow basename: String, in app: XCUIApplication) {
        XCTAssertTrue(group.waitForExistence(timeout: 10), "no Worktrees disclosure triangle")
        let height = group.frame.height
        func rowAppeared(_ timeout: TimeInterval) -> Bool {
            waitFor({ !self.worktreeRows(basename, in: app).isEmpty }, timeout: timeout)
        }
        group.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 25, dy: height / 2)).click()
        if rowAppeared(3) { return }
        group.click()
        XCTAssertTrue(rowAppeared(10), "the Worktrees group did not expand")
    }

    @MainActor
    private func isCurrent(_ element: XCUIElement) -> Bool {
        element.label.components(separatedBy: ", ").contains("current")
    }

    // MARK: - Tests

    @MainActor
    func testPaneOnMainListsAllWorktreesAndMarksMainCurrent() throws {
        let (app, session) = try launch()
        defer { app.terminate() }
        let fixture = try buildFixture(source: session.focusedPaneID)
        try openGitStatus(path: fixture.main, source: session.focusedPaneID, expectingPaneCount: 1, in: app)

        let group = worktreesGroup(in: app)
        XCTAssertTrue(group.waitForExistence(timeout: 20), "no Worktrees group")
        XCTAssertTrue(waitFor({ group.label.contains("Worktrees (3)") }, timeout: 10), "group label was '\(group.label)'")
        expand(group, expectingRow: "wt-main", in: app)

        for name in ["wt-main", "wt-branch", "wt detached"] {
            XCTAssertTrue(waitFor({ !self.worktreeRows(name, in: app).isEmpty }, timeout: 10), "no row for \(name)")
        }
        XCTAssertTrue(isCurrent(try XCTUnwrap(worktreeRows("wt-main", in: app).first)))
        XCTAssertFalse(isCurrent(try XCTUnwrap(worktreeRows("wt-branch", in: app).first)))
        let detached = try XCTUnwrap(worktreeRows("wt detached", in: app).first)
        XCTAssertFalse(isCurrent(detached))
        XCTAssertTrue(detached.label.contains("detached @"), "detached row label was '\(detached.label)'")
    }

    @MainActor
    func testPaneOnALinkedWorktreeMarksThatWorktreeCurrent() throws {
        let (app, session) = try launch()
        defer { app.terminate() }
        let fixture = try buildFixture(source: session.focusedPaneID)
        try openGitStatus(path: fixture.branchWorktree, source: session.focusedPaneID, expectingPaneCount: 1, in: app)

        let group = worktreesGroup(in: app)
        XCTAssertTrue(group.waitForExistence(timeout: 20), "no Worktrees group")
        expand(group, expectingRow: "wt-branch", in: app)
        XCTAssertTrue(waitFor({ !self.worktreeRows("wt-branch", in: app).isEmpty }, timeout: 10), "no row for wt-branch")

        let branchRow = try XCTUnwrap(worktreeRows("wt-branch", in: app).first)
        XCTAssertTrue(isCurrent(branchRow))
        XCTAssertTrue(branchRow.label.contains("wt-branch-name"), "branch row label was '\(branchRow.label)'")
        XCTAssertFalse(isCurrent(try XCTUnwrap(worktreeRows("wt-main", in: app).first)))
    }

    @MainActor
    func testAddingAWorktreeUpdatesTheCountWithoutRefreshing() throws {
        let (app, session) = try launch()
        defer { app.terminate() }
        let fixture = try buildFixture(source: session.focusedPaneID)
        try openGitStatus(path: fixture.main, source: session.focusedPaneID, expectingPaneCount: 1, in: app)

        let group = worktreesGroup(in: app)
        XCTAssertTrue(group.waitForExistence(timeout: 20), "no Worktrees group")
        XCTAssertTrue(waitFor({ group.label.contains("Worktrees (3)") }, timeout: 10), "group label was '\(group.label)'")

        let q = BattyCLI.shellQuoted
        let done = BattyUITestHarness.sentinelPath(named: "worktree-add-done")
        let body = """
        set -e
        cd \(q(fixture.main))
        git worktree add -q --detach \(q(fixture.fourthWorktree))
        touch \(q(done))
        exec sleep 3600
        """
        let pane = try runScript(body, named: "worktree-add.sh", source: session.focusedPaneID)
        XCTAssertTrue(BattyUITestHarness.waitForFile(at: done, timeout: 60), "the worktree add script never finished")
        XCTAssertTrue(waitFor({ group.label.contains("Worktrees (4)") }, timeout: 30), "group label stayed '\(group.label)' without a refresh")
        BattyCLI.runExpectingSuccess(["pane", "close", "--pane", pane.uuidString])
    }

    @MainActor
    func testSingleCheckoutHasNoWorktreesGroup() throws {
        let (app, session) = try launch()
        defer { app.terminate() }
        let repo = try BattyCLI.makeGitRepository(in: scratch)
        try openGitStatus(path: repo.path, source: session.focusedPaneID, expectingPaneCount: 1, in: app)
        XCTAssertTrue(BattyScreen.element("git-status.snapshot", in: app).waitForExistence(timeout: 15))
        XCTAssertFalse(worktreesGroup(in: app).exists)
    }
}
