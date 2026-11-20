// CLIServersListTests.swift

import Darwin
import XCTest

/// `batty server start|share|list|stop|unshare|tailnet` and the toolbar's
/// Servers list against the real app (#0648, #0691, #0692, #0694). The server
/// is Python's `http.server`, run by Batty in a terminal Pane on a free port
/// a helper Pane finds (the runner itself can't bind a socket).
nonisolated final class CLIServersListTests: XCTestCase {
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
        let (_, initial) = try BattyCLI.connect(to: app, from: CLIServersListTests.self)
        return (app, try XCTUnwrap(initial.selectedSession))
    }

    /// A port nothing listens on right now. The sandboxed runner can't bind
    /// a socket, so a helper Pane Batty runs binds port 0 and writes the port
    /// it got to a sentinel; the helper Pane is closed again and focus put
    /// back on `paneID`.
    @MainActor
    private func freePort(from paneID: UUID) throws -> Int {
        let scratch = try BattyCLI.makeScratchDirectory()
        let sentinel = BattyUITestHarness.sentinelPath(named: "server-port")
        let python = "import socket; s = socket.socket(); s.bind(('127.0.0.1', 0)); print(s.getsockname()[1])"
        let staging = BattyCLI.shellQuoted(sentinel + ".tmp")
        let body = "/usr/bin/python3 -c \(BattyCLI.shellQuoted(python)) > \(staging) && mv \(staging) \(BattyCLI.shellQuoted(sentinel))"
        let script = try BattyCLI.makeScript(in: scratch, named: "free-port.sh", body: body)
        let split = BattyCLI.runExpectingSuccess(["pane", "split", "--pane", paneID.uuidString, "--command", script])
        let helper = try XCTUnwrap(split.ids.last, "pane split printed no id: \(split.summary)")
        XCTAssertTrue(BattyUITestHarness.waitForFile(at: sentinel, timeout: 30), "the port helper never wrote a port")
        _ = BattyCLI.run(["pane", "close", "--pane", helper.uuidString])
        XCTAssertNotNil(BattyCLI.waitForTopology { $0.pane(helper) == nil }, "the port helper Pane did not close")
        _ = BattyCLI.run(["pane", "focus", paneID.uuidString])
        let text = BattyCLI.readTrimmed(sentinel)
        return try XCTUnwrap(text.flatMap(Int.init), "the port helper wrote \(text ?? "nothing")")
    }

    private func pythonServer(_ port: Int) -> [String] {
        ["/usr/bin/python3", "-m", "http.server", String(port), "--bind", "127.0.0.1"]
    }

    private func start(_ port: Int, from pane: UUID) -> CLIResult {
        BattyCLI.run(["server", "start", "--port", String(port), "--pane", pane.uuidString, "--wait", "--timeout", "30", "--json", "--"] + pythonServer(port))
    }

    private func reply(_ result: CLIResult) throws -> [String: Any] {
        try XCTUnwrap(CLITopology.jsonObject(in: result.output), "no JSON reply: \(result.summary)")
    }

    @MainActor
    /// macOS exposes a SwiftUI `Text`'s string as its AX value, with an
    /// empty label.
    private func text(of element: XCUIElement) -> String {
        let label = element.label
        return label.isEmpty ? (element.value as? String ?? "") : label
    }

    private func serverID(_ json: [String: Any]) throws -> UUID {
        try XCTUnwrap((json["serverID"] as? String).flatMap(UUID.init(uuidString:)), "no serverID in \(json)")
    }

    @MainActor
    private func serversButton(in app: XCUIApplication) -> XCUIElement {
        BattyScreen.element("toolbar.servers", in: app)
    }

    @MainActor
    private func openRow(_ id: UUID, in app: XCUIApplication) -> XCUIElement {
        let button = serversButton(in: app)
        XCTAssertTrue(button.waitForExistence(timeout: 10), "no Servers toolbar button")
        button.click()
        let row = BattyScreen.element("servers.row.\(id.uuidString)", in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 10), "no Servers row for \(id)")
        return row
    }

    // MARK: - Tests

    @MainActor
    func testFreshLaunchShowsNoServersButton() throws {
        let (app, _) = try launch()
        defer { app.terminate() }
        XCTAssertTrue(BattyScreen.element("toolbar.bell-feed", in: app).waitForExistence(timeout: 10))
        XCTAssertFalse(serversButton(in: app).exists, "a fresh launch shows the Servers button")
    }

    @MainActor
    func testServerStartShowsServersButtonWithItsPort() throws {
        let (app, session) = try launch()
        defer { app.terminate() }
        let port = try freePort(from: session.focusedPaneID)
        let result = start(port, from: session.focusedPaneID)
        XCTAssertEqual(result.status, 0, result.summary)
        let json = try reply(result)
        XCTAssertEqual(json["state"] as? String, "listening")
        let id = try serverID(json)
        let terminalID = try XCTUnwrap((json["terminalPaneID"] as? String).flatMap(UUID.init(uuidString:)))

        let topology = try XCTUnwrap(BattyCLI.waitForTopology { $0.pane(terminalID) != nil })
        XCTAssertEqual(topology.pane(terminalID)?.kind, "terminal")
        let panes = try XCTUnwrap(topology.session(session.id)?.panes)
        XCTAssertEqual(panes.filter { $0.kind != "terminal" }.map(\.kind), ["process-status"], "server start should open exactly one Process Status Pane besides terminals")
        XCTAssertEqual(topology.session(session.id)?.focusedPaneID, session.focusedPaneID, "server start moved keyboard focus")

        let row = openRow(id, in: app)
        let portText = row.descendants(matching: .any).matching(identifier: "servers.port").firstMatch
        XCTAssertTrue(portText.waitForExistence(timeout: 5))
        XCTAssertEqual(text(of: portText), "127.0.0.1:\(port)")
        XCTAssertTrue(row.descendants(matching: .any).matching(identifier: "servers.copy-url").firstMatch.exists)
        app.typeKey(.escape, modifierFlags: [])
        _ = BattyCLI.run(["server", "stop", id.uuidString])
    }

    @MainActor
    func testServerStopRemovesTheServersButton() throws {
        let (app, session) = try launch()
        defer { app.terminate() }
        let port = try freePort(from: session.focusedPaneID)
        let id = try serverID(reply(start(port, from: session.focusedPaneID)))
        XCTAssertTrue(serversButton(in: app).waitForExistence(timeout: 10), "no Servers toolbar button while a server runs")
        let stop = BattyCLI.run(["server", "stop", id.uuidString, "--json"])
        XCTAssertEqual(stop.status, 0, stop.summary)
        XCTAssertEqual(try reply(stop)["state"] as? String, "stopped")
        XCTAssertTrue(BattyUITestHarness.waitFor({ !self.serversButton(in: app).exists }, timeout: 10), "the Servers button stayed after stop")
        let share = BattyCLI.run(["server", "share", "--port", String(port), "--no-process-view", "--json"])
        XCTAssertNotEqual(share.status, 0, "something still listens on \(port) after stop: \(share.summary)")
        if share.status == 0, let shared = try? serverID(reply(share)) { _ = BattyCLI.run(["server", "unshare", shared.uuidString]) }
    }

    @MainActor
    func testServerStartTwiceOnSamePortReusesTheEntry() throws {
        let (app, session) = try launch()
        defer { app.terminate() }
        let port = try freePort(from: session.focusedPaneID)
        let first = try reply(start(port, from: session.focusedPaneID))
        let paneCount = try XCTUnwrap(BattyCLI.topology()?.session(session.id)?.panes.count)
        let second = start(port, from: session.focusedPaneID)
        XCTAssertEqual(second.status, 0, second.summary)
        let secondJSON = try reply(second)
        XCTAssertEqual(secondJSON["serverID"] as? String, first["serverID"] as? String)
        XCTAssertEqual(secondJSON["tabID"] as? String, first["tabID"] as? String)
        XCTAssertEqual(secondJSON["created"] as? Bool, false)
        XCTAssertEqual(BattyCLI.topology()?.session(session.id)?.panes.count, paneCount)
        _ = openRow(try serverID(first), in: app)
        XCTAssertEqual(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'servers.row.'")).count, 1)
        app.typeKey(.escape, modifierFlags: [])
        _ = BattyCLI.run(["server", "stop", "--port", String(port)])
    }

    private func processStatusPanes(in session: UUID) -> [UUID] {
        (BattyCLI.topology()?.session(session)?.panes ?? []).filter { $0.kind == "process-status" }.map(\.id)
    }

    @MainActor
    func testServerShareListsTheServerAndOpensAProcessStatusPane() throws {
        let (app, session) = try launch()
        defer { app.terminate() }
        let port = try freePort(from: session.focusedPaneID)
        let command = pythonServer(port).joined(separator: " ")
        let terminal = BattyCLI.runExpectingSuccess(["pane", "split", "--pane", session.focusedPaneID.uuidString, "-c", command])
        let terminalID = try XCTUnwrap(terminal.ids.last)
        var share = BattyCLI.run(["server", "share", "--port", String(port), "--pane", session.focusedPaneID.uuidString, "--json"])
        if share.status != 0 {
            XCTAssertTrue(BattyUITestHarness.waitFor({
                share = BattyCLI.run(["server", "share", "--port", String(port), "--pane", session.focusedPaneID.uuidString, "--json"])
                return share.status == 0
            }, timeout: 30), "server share never found the listener: \(share.summary)")
        }
        let json = try reply(share)
        XCTAssertEqual(json["kind"] as? String, "external")
        let id = try serverID(json)
        let processPane = try XCTUnwrap((json["processPaneID"] as? String).flatMap(UUID.init(uuidString:)), "no processPaneID in \(json)")
        XCTAssertNotNil(BattyCLI.waitForTopology { $0.pane(processPane) != nil }, "the Process Status Pane never appeared")
        XCTAssertEqual(processStatusPanes(in: session.id), [processPane])
        XCTAssertTrue(BattyScreen.element("process-status-view", in: app).waitForExistence(timeout: 10), "no process-status-view")

        let row = openRow(id, in: app)
        let menu = row.descendants(matching: .any).matching(identifier: "servers.row-menu").firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        menu.click()
        // Scoped to the row menu: app-wide menuItems also match the menu bar's Apple-menu Restart.
        let rowMenu = app.menus.containing(.menuItem, identifier: "servers.row.open-in-browser").firstMatch
        XCTAssertTrue(rowMenu.waitForExistence(timeout: 5))
        XCTAssertFalse(rowMenu.menuItems["servers.row.stop"].exists, "a shared server offers Stop in the Servers list")
        XCTAssertFalse(rowMenu.menuItems["servers.row.restart"].exists, "a shared server offers Restart in the Servers list")
        XCTAssertTrue(rowMenu.menuItems["servers.row.unshare"].exists, "a shared server has no Remove from List")
        app.typeKey(.escape, modifierFlags: [])
        app.typeKey(.escape, modifierFlags: [])

        let again = BattyCLI.run(["server", "share", "--port", String(port), "--json"])
        XCTAssertEqual(again.status, 0, again.summary)
        XCTAssertEqual(try serverID(reply(again)), id)
        XCTAssertEqual(processStatusPanes(in: session.id), [processPane], "a repeated share opened another Process Status Pane")

        let stop = BattyCLI.run(["server", "stop", "--port", String(port)])
        XCTAssertNotEqual(stop.status, 0, "server stop signalled a shared server: \(stop.summary)")
        let unshare = BattyCLI.run(["server", "unshare", "--port", String(port)])
        XCTAssertEqual(unshare.status, 0, unshare.summary)
        let list = BattyCLI.run(["server", "list", "--json"])
        XCTAssertEqual(list.status, 0, list.summary)
        XCTAssertFalse(list.output.contains(id.uuidString), "unshare left the server listed")

        _ = BattyCLI.run(["pane", "close", "--pane", processPane.uuidString])
        _ = BattyCLI.run(["pane", "close", "--pane", terminalID.uuidString])
    }

    @MainActor
    func testServerListPrintsTheStartedServer() throws {
        let (app, session) = try launch()
        defer { app.terminate() }
        let port = try freePort(from: session.focusedPaneID)
        let id = try serverID(reply(start(port, from: session.focusedPaneID)))
        let list = BattyCLI.run(["server", "list", "--json"])
        XCTAssertEqual(list.status, 0, list.summary)
        let json = try reply(list)
        let servers = try XCTUnwrap(json["servers"] as? [[String: Any]], "no servers in \(json)")
        let item = try XCTUnwrap(servers.first { $0["serverID"] as? String == id.uuidString }, "server list is missing \(id)")
        XCTAssertEqual(item["kind"] as? String, "terminal")
        XCTAssertEqual(item["port"] as? Int, port)
        _ = BattyCLI.run(["server", "stop", id.uuidString])
    }

    @MainActor
    func testServerVerbsAbsentWithFlagForcedOff() throws {
        let (app, session) = try launch(extraEnvironment: ["BATTY_UI_TEST_FORCE_SERVERS_OFF": "1"])
        defer { app.terminate() }
        // Never bound: the verb is refused before anything runs.
        let port = 59_999
        let result = BattyCLI.run(["server", "start", "--port", String(port), "--pane", session.focusedPaneID.uuidString, "--"] + pythonServer(port))
        XCTAssertNotEqual(result.status, 0, result.summary)
        let share = BattyCLI.run(["server", "share", "--port", String(port)])
        XCTAssertNotEqual(share.status, 0, share.summary)
        XCTAssertEqual(BattyCLI.topology()?.session(session.id)?.panes.count, session.panes.count, "a flag-off server start changed the layout")
        XCTAssertFalse(serversButton(in: app).exists, "the Servers button shows with the flag off")
    }

    // MARK: - Tailnet (#0694; the fake tailscale runner, never the real CLI)

    /// Runs a python server in a terminal Pane and shares it without a
    /// Process Status Pane. Returns the server id and the terminal Pane.
    @MainActor
    private func sharePythonServer(_ port: Int, from pane: UUID) throws -> (id: UUID, terminal: UUID) {
        let terminal = BattyCLI.runExpectingSuccess(["pane", "split", "--pane", pane.uuidString, "-c", pythonServer(port).joined(separator: " ")])
        let terminalID = try XCTUnwrap(terminal.ids.last)
        let args = ["server", "share", "--port", String(port), "--pane", pane.uuidString, "--no-process-view", "--json"]
        var share = BattyCLI.run(args)
        if share.status != 0 {
            XCTAssertTrue(BattyUITestHarness.waitFor({
                share = BattyCLI.run(args)
                return share.status == 0
            }, timeout: 30), "server share never found the listener: \(share.summary)")
        }
        return (try serverID(reply(share)), terminalID)
    }

    @MainActor
    private func openRowMenu(_ id: UUID, in app: XCUIApplication) -> XCUIElement {
        let row = openRow(id, in: app)
        let menu = row.descendants(matching: .any).matching(identifier: "servers.row-menu").firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        menu.click()
        let rowMenu = app.menus.containing(.menuItem, identifier: "servers.row.open-in-browser").firstMatch
        XCTAssertTrue(rowMenu.waitForExistence(timeout: 5))
        return rowMenu
    }

    @MainActor
    func testServerTailnetShowsCopyTailnetURLAndStopSharing() throws {
        let (app, session) = try launch(extraEnvironment: ["BATTY_UI_TEST_FAKE_TAILSCALE": "running"])
        defer { app.terminate() }
        let port = try freePort(from: session.focusedPaneID)
        let (id, terminal) = try sharePythonServer(port, from: session.focusedPaneID)
        let expected = "https://batty-vm.example.ts.net:\(port)/"

        let tailnet = BattyCLI.run(["server", "tailnet", "--port", String(port), "--json"])
        XCTAssertEqual(tailnet.status, 0, tailnet.summary)
        XCTAssertEqual(try reply(tailnet)["tailnetURL"] as? String, expected)
        let list = BattyCLI.run(["server", "list", "--json"])
        XCTAssertTrue(list.output.contains(expected), "server list --json lacks the tailnet URL: \(list.summary)")

        let row = openRow(id, in: app)
        XCTAssertTrue(row.descendants(matching: .any).matching(identifier: "servers.copy-tailnet-url").firstMatch.waitForExistence(timeout: 10), "no Copy Tailnet URL")
        let menu = row.descendants(matching: .any).matching(identifier: "servers.row-menu").firstMatch
        menu.click()
        let rowMenu = app.menus.containing(.menuItem, identifier: "servers.row.open-in-browser").firstMatch
        XCTAssertTrue(rowMenu.waitForExistence(timeout: 5))
        let stop = rowMenu.menuItems["servers.row.tailnet-unshare"]
        XCTAssertTrue(stop.exists, "a tailnet-shared server has no Stop Sharing on Tailnet")
        stop.click()
        let copy = row.descendants(matching: .any).matching(identifier: "servers.copy-tailnet-url").firstMatch
        XCTAssertTrue(BattyUITestHarness.waitFor({ !copy.exists }, timeout: 10), "Copy Tailnet URL stayed after Stop Sharing")
        menu.click()
        XCTAssertTrue(rowMenu.menuItems["servers.row.tailnet-share"].waitForExistence(timeout: 5), "no Share on Tailnet after stopping")
        app.typeKey(.escape, modifierFlags: [])
        app.typeKey(.escape, modifierFlags: [])

        _ = BattyCLI.run(["server", "unshare", "--port", String(port)])
        _ = BattyCLI.run(["pane", "close", "--pane", terminal.uuidString])
    }

    @MainActor
    func testNoTailnetActionWithoutTailscale() throws {
        let (app, session) = try launch(extraEnvironment: ["BATTY_UI_TEST_FAKE_TAILSCALE": "absent"])
        defer { app.terminate() }
        let port = try freePort(from: session.focusedPaneID)
        let (id, terminal) = try sharePythonServer(port, from: session.focusedPaneID)

        let rowMenu = openRowMenu(id, in: app)
        XCTAssertFalse(rowMenu.menuItems["servers.row.tailnet-share"].exists, "Share on Tailnet shows without Tailscale")
        app.typeKey(.escape, modifierFlags: [])
        app.typeKey(.escape, modifierFlags: [])

        let tailnet = BattyCLI.run(["server", "tailnet", "--port", String(port)])
        XCTAssertNotEqual(tailnet.status, 0, tailnet.summary)
        XCTAssertTrue(tailnet.summary.contains("isn't installed"), tailnet.summary)

        _ = BattyCLI.run(["server", "unshare", "--port", String(port)])
        _ = BattyCLI.run(["pane", "close", "--pane", terminal.uuidString])
    }
}
