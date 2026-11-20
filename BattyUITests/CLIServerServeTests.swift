// CLIServerServeTests.swift

import XCTest

/// `batty server serve` against the real app (#0649). The server
/// runs inside Batty, so the sandboxed runner never binds a socket.
nonisolated final class CLIServerServeTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        BattyUITestHarness.sweepSentinels()
    }

    override func tearDownWithError() throws {
        BattyUITestHarness.sweepSentinels()
    }

    // MARK: - Helpers

    @MainActor
    private func launch(extraEnvironment: [String: String] = [:]) throws -> (app: XCUIApplication, session: CLITopology.Session) {
        let app = extraEnvironment.isEmpty
            ? BattyUITestHarness.launchBatty()
            : BattyUITestHarness.launchBatty(script: [], extraEnvironment: extraEnvironment)
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10), "Batty did not open a window")
        let (_, initial) = try BattyCLI.connect(to: app, from: CLIServerServeTests.self)
        return (app, try XCTUnwrap(initial.selectedSession))
    }

    private func site(heading: String = "Batty preview fixture one") throws -> URL {
        let scratch = try BattyCLI.makeScratchDirectory()
        let root = scratch.appending(path: "site")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try page(heading).write(to: root.appending(path: "index.html"), atomically: true, encoding: .utf8)
        return root
    }

    private func page(_ heading: String) -> String {
        "<!doctype html><html><head><title>fixture</title></head><body><h1>\(heading)</h1></body></html>\n"
    }

    private func serve(_ root: URL, from pane: UUID, _ extra: [String] = []) -> CLIResult {
        BattyCLI.run(["server", "serve", root.path, "--pane", pane.uuidString, "--json"] + extra)
    }

    private func reply(_ result: CLIResult) throws -> [String: Any] {
        try XCTUnwrap(CLITopology.jsonObject(in: result.output), "no JSON reply: \(result.summary)")
    }

    @MainActor
    private func text(of element: XCUIElement) -> String {
        let label = element.label
        return label.isEmpty ? (element.value as? String ?? "") : label
    }

    // MARK: - Tests

    @MainActor
    func testServeListsTheFolderInServers() throws {
        let (app, session) = try launch()
        defer { app.terminate() }
        let root = try site()
        let result = serve(root, from: session.focusedPaneID)
        XCTAssertEqual(result.status, 0, result.summary)
        let json = try reply(result)
        let serverID = try XCTUnwrap((json["serverID"] as? String).flatMap(UUID.init(uuidString:)))
        XCTAssertTrue((json["url"] as? String)?.hasPrefix("http://127.0.0.1:") == true)
        XCTAssertEqual(BattyCLI.topology()?.session(session.id)?.panes.count, session.panes.count, "serve opened a Pane")
        let button = BattyScreen.element("toolbar.servers", in: app)
        XCTAssertTrue(button.waitForExistence(timeout: 10), "no Servers toolbar button while serving")
        button.click()
        let row = BattyScreen.element("servers.row.\(serverID.uuidString)", in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertTrue(row.descendants(matching: .any).matching(NSPredicate(format: "label == 'site' OR value == 'site'")).firstMatch.waitForExistence(timeout: 5), "the row is not named after the folder")
        let state = row.descendants(matching: .any).matching(identifier: "servers.state").firstMatch
        XCTAssertTrue(BattyUITestHarness.waitFor({ self.text(of: state) == "Serving" }, timeout: 15), "state reads \(text(of: state))")
        app.typeKey(.escape, modifierFlags: [])
        _ = BattyCLI.run(["server", "stop", serverID.uuidString])
    }

    @MainActor
    func testServerStopFreesThePort() throws {
        let (app, session) = try launch()
        defer { app.terminate() }
        let root = try site()
        let json = try reply(serve(root, from: session.focusedPaneID))
        let serverID = try XCTUnwrap(json["serverID"] as? String)
        let url = try XCTUnwrap(json["url"] as? String)
        let port = try XCTUnwrap(URLComponents(string: url)?.port)
        BattyCLI.runExpectingSuccess(["server", "stop", serverID])
        let again = serve(root, from: session.focusedPaneID, ["--port", String(port)])
        XCTAssertEqual(again.status, 0, again.summary)
        XCTAssertEqual(try reply(again)["url"] as? String, url)
        if let id = try reply(again)["serverID"] as? String { _ = BattyCLI.run(["server", "stop", id]) }
    }

    @MainActor
    func testServerPreviewIsUnknown() throws {
        let (app, session) = try launch()
        defer { app.terminate() }
        let result = BattyCLI.run(["server", "preview", "--port", "8083", "--pane", session.focusedPaneID.uuidString])
        XCTAssertNotEqual(result.status, 0, result.summary)
        XCTAssertEqual(BattyCLI.topology()?.session(session.id)?.panes.count, session.panes.count, "server preview changed the layout")
    }

    @MainActor
    func testServeAbsentWithFlagForcedOff() throws {
        let (app, session) = try launch(extraEnvironment: ["BATTY_UI_TEST_FORCE_SERVERS_OFF": "1"])
        defer { app.terminate() }
        let serveResult = serve(try site(), from: session.focusedPaneID)
        XCTAssertNotEqual(serveResult.status, 0, serveResult.summary)
        XCTAssertEqual(BattyCLI.topology()?.session(session.id)?.panes.count, session.panes.count, "a flag-off serve changed the layout")
    }
}
