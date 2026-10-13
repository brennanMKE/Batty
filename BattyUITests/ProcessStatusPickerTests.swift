// ProcessStatusPickerTests.swift

import Darwin
import XCTest

/// The Process Status Pane's "Pick a Running Process…" popover: the filter
/// field and follow-by-name (#0486).
///
/// The fixture is a uniquely named copy of `/bin/sleep` (at most 15
/// characters, inside `MAXCOMLEN`, so the name is never truncated) started in
/// a terminal Pane through `batty pane split --command` (a script file, as the other CLI tests do). It cannot be started
/// from the test process: the UI-test runner is sandboxed and exec of a file
/// it wrote is refused (`EPERM`), and a symlink to `/bin/sleep` is listed as
/// `sleep`. Batty is unsandboxed and shares the runner's uid, so the picker
/// lists the fixture. Its pid is read from the picker's row identifier, and
/// it is stopped by closing its Pane.
nonisolated final class ProcessStatusPickerTests: XCTestCase {
    private var fixtureName: String!
    private var fixturePath: String!
    private var scratch: URL!
    private var errorLogPath: String { NSTemporaryDirectory() + "bt-fixture-errors.log" }

    override func setUpWithError() throws {
        continueAfterFailure = false
        BattyUITestHarness.sweepSentinels()
        scratch = try BattyCLI.makeScratchDirectory()
        fixtureName = "bt-follow-" + UUID().uuidString.prefix(5).lowercased()
        fixturePath = "/tmp/" + fixtureName
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: fixturePath)
        BattyUITestHarness.sweepSentinels()
    }

    // MARK: - Helpers

    @MainActor
    private func launchWithProcessStatusPane() throws -> (app: XCUIApplication, terminal: UUID) {
        let app = BattyUITestHarness.launchBatty()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10), "Batty did not open a window")
        let (_, initial) = try BattyCLI.connect(to: app, from: ProcessStatusPickerTests.self)
        let session = try XCTUnwrap(initial.selectedSession)
        let result = BattyCLI.runExpectingSuccess(["pane", "split", "--view", "process-status", "--pane", session.focusedPaneID.uuidString])
        XCTAssertNotNil(result.ids.last, "pane split --view process-status printed no id")
        XCTAssertTrue(BattyScreen.element("process-status-view", in: app).waitForExistence(timeout: 15))
        return (app, session.focusedPaneID)
    }

    /// Splits `terminal` with a Pane that copies `/bin/sleep` to the fixture
    /// path (once) and runs it, so the fixture is a child of the Pane's shell.
    @MainActor
    @discardableResult
    private func startFixture(from terminal: UUID) throws -> UUID {
        let body = """
        [ -x \(fixturePath!) ] || cp /bin/sleep \(fixturePath!) 2>>\(errorLogPath)
        \(fixturePath!) 300 2>>\(errorLogPath)
        echo rc=$? >>\(errorLogPath)
        """
        let command = try BattyCLI.makeScript(in: scratch, named: "fixture-\(UUID().uuidString.prefix(6)).sh", body: body)
        let result = BattyCLI.runExpectingSuccess(["pane", "split", "--pane", terminal.uuidString, "--command", command])
        return try XCTUnwrap(result.ids.last, "pane split --command printed no id")
    }

    @MainActor
    private func stopFixture(_ pane: UUID) {
        BattyCLI.runExpectingSuccess(["pane", "close", "--pane", pane.uuidString])
    }

    @MainActor
    private func openPicker(_ app: XCUIApplication) {
        let choose = BattyScreen.element("process-status.choose-process", in: app)
        XCTAssertTrue(choose.waitForExistence(timeout: 10), "no Choose Process… menu")
        choose.click()
        let item = app.menuItems["Pick a Running Process…"]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "no Pick a Running Process… item")
        item.click()
        let opened = BattyScreen.element("process-status.picker.filter-field", in: app).waitForExistence(timeout: 10)
        XCTAssertTrue(opened, "the picker did not open; popovers=\(app.popovers.count)")
    }

    /// Resolving every row of an unfiltered list element by element takes
    /// minutes under XCUITest (hundreds of rows), so rows are counted and
    /// addressed through the query instead of enumerated.
    @MainActor
    private func rows(_ app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "process-status.picker.row."))
    }

    @MainActor
    private func value(_ identifier: String, in app: XCUIApplication) -> String? {
        BattyScreen.element(identifier, in: app).value as? String
    }

    @MainActor
    private func pid(ofRow identifier: String) -> pid_t? {
        pid_t(identifier.dropFirst("process-status.picker.row.".count))
    }

    /// Opens the picker filtered to the fixture's name and returns its pid,
    /// reopening until the freshly started fixture is listed (the list is
    /// fetched once per open). Leaves the picker open with the name typed.
    @MainActor
    private func openPickerOnFixture(_ app: XCUIApplication, excluding stale: pid_t? = nil) throws -> pid_t {
        var lastTree: [String] = []
        for _ in 0..<6 {
            openPicker(app)
            app.typeText(fixtureName)
            var found: pid_t?
            waitFor({
                let rows = self.rows(app)
                guard rows.count == 1, let pid = self.pid(ofRow: rows.element(boundBy: 0).identifier), pid != stale else { return false }
                found = pid
                return true
            }, timeout: 5)
            if let found { return found }
            lastTree = app.popovers.firstMatch.descendants(matching: .any).allElementsBoundByIndex.prefix(30)
                .map { "\($0.elementType.rawValue)|\($0.identifier)|\($0.label)" }
            app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
            app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
            XCTAssertTrue(waitFor({ !app.popovers.firstMatch.exists }, timeout: 10))
        }
        XCTFail("the fixture \(fixtureName!) never appeared in the picker; tree=\(lastTree) fixtureLog=\(String(describing: try? String(contentsOfFile: errorLogPath, encoding: .utf8)))")
        throw XCTestError(.failureWhileWaiting)
    }

    // MARK: - Tests

    @MainActor
    func testFilterByNameNarrowsToTheFixtureAndReturnPinsIt() throws {
        let (app, terminal) = try launchWithProcessStatusPane()
        defer { app.terminate() }
        try startFixture(from: terminal)

        let pid = try openPickerOnFixture(app)
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
        XCTAssertTrue(waitFor({ self.value("process-status.pid", in: app) == String(pid) }, timeout: 15))
        XCTAssertEqual(value("process-status.mode", in: app), "pinned")
    }

    @MainActor
    func testFilterByPidListsItFirstAndEscapeClearsThenDismisses() throws {
        let (app, terminal) = try launchWithProcessStatusPane()
        defer { app.terminate() }
        try startFixture(from: terminal)

        let pid = try openPickerOnFixture(app)
        let expected = "process-status.picker.row.\(pid)"
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        XCTAssertTrue(waitFor({ self.rows(app).count > 1 }, timeout: 10), "Escape should clear the query and bring the rows back")
        let unfiltered = rows(app).count

        app.typeText(String(pid))
        XCTAssertTrue(waitFor({ BattyScreen.element(expected, in: app).exists }, timeout: 10))
        XCTAssertEqual(rows(app).element(boundBy: 0).identifier, expected, "an exact pid match is listed first")
        XCTAssertLessThanOrEqual(rows(app).count, unfiltered)

        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        XCTAssertTrue(waitFor({ self.rows(app).count > 1 }, timeout: 10), "Escape should clear the query and bring the rows back")
        XCTAssertTrue(app.popovers.firstMatch.exists)

        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        XCTAssertTrue(waitFor({ !app.popovers.firstMatch.exists }, timeout: 10), "a second Escape should dismiss the popover")

        openPicker(app)
        app.typeText(String(pid))
        XCTAssertTrue(waitFor({ BattyScreen.element(expected, in: app).exists }, timeout: 10))
        app.typeKey(XCUIKeyboardKey.downArrow.rawValue, modifierFlags: [])
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
        XCTAssertTrue(waitFor({ self.value("process-status.pid", in: app) == String(pid) }, timeout: 15), "Down then Return should pick the highlighted exact-pid row")
    }

    @MainActor
    func testNoMatchShowsTheEmptyState() throws {
        let (app, _) = try launchWithProcessStatusPane()
        defer { app.terminate() }

        openPicker(app)
        app.typeText("zz-no-such-process-\(UUID().uuidString.prefix(8))")
        XCTAssertTrue(BattyScreen.element("process-status.picker.empty", in: app).waitForExistence(timeout: 10))
        XCTAssertEqual(rows(app).count, 0)
    }

    @MainActor
    func testFollowByNameReconnectsToEachReplacement() throws {
        let (app, terminal) = try launchWithProcessStatusPane()
        defer { app.terminate() }
        var fixturePane = try startFixture(from: terminal)

        var current = try openPickerOnFixture(app)
        let toggle = BattyScreen.element("process-status.picker.follow-by-name", in: app)
        XCTAssertTrue(toggle.exists)
        toggle.click()
        BattyScreen.element("process-status.picker.row.\(current)", in: app).click()

        XCTAssertTrue(waitFor({ self.value("process-status.pid", in: app) == String(current) }, timeout: 15))
        XCTAssertEqual(value("process-status.mode", in: app), "following-name")

        for round in 1...2 {
            stopFixture(fixturePane)
            XCTAssertTrue(
                waitFor({ self.value("process-status.state-chip", in: app) == "waiting" }, timeout: 20),
                "round \(round): chip was \(String(describing: value("process-status.state-chip", in: app)))"
            )
            XCTAssertTrue(BattyScreen.element("process-status.waiting-banner", in: app).waitForExistence(timeout: 10))

            fixturePane = try startFixture(from: terminal)
            XCTAssertTrue(
                waitFor({
                    guard let shown = self.value("process-status.pid", in: app), let pid = pid_t(shown) else { return false }
                    return pid != current
                }, timeout: 20),
                "round \(round): pid stayed \(String(describing: value("process-status.pid", in: app)))"
            )
            XCTAssertTrue(waitFor({ self.value("process-status.state-chip", in: app) == "running" }, timeout: 15))
            XCTAssertEqual(value("process-status.mode", in: app), "following-name")
            XCTAssertFalse(BattyScreen.element("process-status.waiting-banner", in: app).exists)
            current = try XCTUnwrap(self.value("process-status.pid", in: app).flatMap { pid_t($0) })
        }
    }
}
