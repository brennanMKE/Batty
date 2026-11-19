// CLIServerPaneTests.swift

import Darwin
import XCTest

/// `batty server start|attach|stop` against the real app (#0648). The server
/// is Python's `http.server`, run by Batty in a terminal Pane on a free port
/// a helper Pane finds (the runner itself can't bind a socket).
nonisolated final class CLIServerPaneTests: XCTestCase {
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
        let (_, initial) = try BattyCLI.connect(to: app, from: CLIServerPaneTests.self)
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
    private func stateText(in app: XCUIApplication) -> String {
        let chip = BattyScreen.element("server-pane-state", in: app)
        let label = chip.label
        return label.isEmpty ? (chip.value as? String ?? "") : label
    }

    // MARK: - Tests

    @MainActor
    func testServerStartShowsServerPaneAndTerminalAndReachesListening() throws {
        let (app, session) = try launch()
        defer { app.terminate() }
        let port = try freePort(from: session.focusedPaneID)
        let result = start(port, from: session.focusedPaneID)
        XCTAssertEqual(result.status, 0, result.summary)
        let json = try reply(result)
        XCTAssertEqual(json["state"] as? String, "listening")
        let serverID = try XCTUnwrap((json["paneID"] as? String).flatMap(UUID.init(uuidString:)))
        let terminalID = try XCTUnwrap((json["terminalPaneID"] as? String).flatMap(UUID.init(uuidString:)))

        let topology = try XCTUnwrap(BattyCLI.waitForTopology(includeDimensions: true) { $0.pane(serverID) != nil && $0.pane(terminalID) != nil })
        XCTAssertEqual(topology.pane(serverID)?.kind, "server")
        XCTAssertEqual(topology.pane(terminalID)?.kind, "terminal")
        XCTAssertEqual(topology.session(session.id)?.focusedPaneID, session.focusedPaneID, "server start moved keyboard focus")

        // Topology frames come from terminal views only, so the layout is
        // checked on screen (y grows downward).
        let serverPane = BattyScreen.element("server-pane.\(serverID.uuidString)", in: app)
        let terminalPane = BattyScreen.terminalPane(terminalID, in: app)
        XCTAssertTrue(serverPane.waitForExistence(timeout: 10))
        XCTAssertTrue(terminalPane.waitForExistence(timeout: 10))
        XCTAssertGreaterThanOrEqual(terminalPane.frame.minY, serverPane.frame.maxY - 2, "the terminal Pane is not below the Server Pane")
        XCTAssertTrue(BattyUITestHarness.waitFor({ self.stateText(in: app) == "Listening" }, timeout: 15), "state chip reads \(stateText(in: app))")
        _ = BattyCLI.run(["server", "stop", "--port", String(port), "--pane", session.focusedPaneID.uuidString])
    }

    @MainActor
    func testServerStartTwiceOnSamePortReusesThePane() throws {
        let (app, session) = try launch()
        defer { app.terminate() }
        let port = try freePort(from: session.focusedPaneID)
        let first = try reply(start(port, from: session.focusedPaneID))
        let paneCount = try XCTUnwrap(BattyCLI.topology()?.session(session.id)?.panes.count)
        let second = start(port, from: session.focusedPaneID)
        XCTAssertEqual(second.status, 0, second.summary)
        let secondJSON = try reply(second)
        XCTAssertEqual(secondJSON["paneID"] as? String, first["paneID"] as? String)
        XCTAssertEqual(secondJSON["tabID"] as? String, first["tabID"] as? String)
        XCTAssertEqual(secondJSON["created"] as? Bool, false)
        XCTAssertEqual(BattyCLI.topology()?.session(session.id)?.panes.count, paneCount)
        _ = BattyCLI.run(["server", "stop", "--port", String(port), "--pane", session.focusedPaneID.uuidString])
    }

    @MainActor
    func testServerStopEndsTheProcessGroupAndShowsStopped() throws {
        let (app, session) = try launch()
        defer { app.terminate() }
        let port = try freePort(from: session.focusedPaneID)
        XCTAssertEqual(start(port, from: session.focusedPaneID).status, 0)
        let stop = BattyCLI.run(["server", "stop", "--port", String(port), "--pane", session.focusedPaneID.uuidString, "--json"])
        XCTAssertEqual(stop.status, 0, stop.summary)
        XCTAssertEqual(try reply(stop)["state"] as? String, "stopped")
        XCTAssertTrue(BattyUITestHarness.waitFor({ self.stateText(in: app) == "Stopped" }, timeout: 10), "state chip reads \(stateText(in: app))")
        let attach = BattyCLI.run(["server", "attach", "--port", String(port), "--pane", session.focusedPaneID.uuidString, "--json"])
        XCTAssertNotEqual(try reply(attach)["state"] as? String, "listening", "something still listens on \(port) after stop")
    }

    @MainActor
    func testCloseServerPaneLeavesTerminalPaneRunning() throws {
        let (app, session) = try launch()
        defer { app.terminate() }
        let port = try freePort(from: session.focusedPaneID)
        let json = try reply(start(port, from: session.focusedPaneID))
        let serverID = try XCTUnwrap(json["paneID"] as? String)
        let terminalID = try XCTUnwrap((json["terminalPaneID"] as? String).flatMap(UUID.init(uuidString:)))
        BattyCLI.runExpectingSuccess(["pane", "close", "--pane", serverID])
        let topology = try XCTUnwrap(BattyCLI.waitForTopology { $0.pane(UUID(uuidString: serverID)!) == nil })
        XCTAssertNotNil(topology.pane(terminalID), "closing the Server Pane closed its terminal Pane")
        let attach = try reply(BattyCLI.run(["server", "attach", "--port", String(port), "--pane", session.focusedPaneID.uuidString, "--wait", "--timeout", "10", "--json"]))
        XCTAssertEqual(attach["state"] as? String, "listening", "closing the Server Pane stopped the server")
        _ = BattyCLI.run(["server", "stop", "--port", String(port), "--pane", session.focusedPaneID.uuidString])
    }

    @MainActor
    func testServerAttachShowsExternalListenerWithoutRestart() throws {
        let (app, session) = try launch()
        defer { app.terminate() }
        let port = try freePort(from: session.focusedPaneID)
        let command = pythonServer(port).joined(separator: " ")
        let terminal = BattyCLI.runExpectingSuccess(["pane", "split", "--pane", session.focusedPaneID.uuidString, "-c", command])
        let terminalID = try XCTUnwrap(terminal.ids.last)
        let attach = BattyCLI.run(["server", "attach", "--port", String(port), "--pane", session.focusedPaneID.uuidString, "--wait", "--timeout", "30", "--json"])
        XCTAssertEqual(attach.status, 0, attach.summary)
        let json = try reply(attach)
        XCTAssertEqual(json["state"] as? String, "listening")
        XCTAssertNotNil(json["pid"])
        XCTAssertTrue(BattyScreen.element("server-pane-pid", in: app).waitForExistence(timeout: 10))
        XCTAssertFalse(BattyScreen.element("server-pane-restart", in: app).exists, "an attached server without --command offers Restart")
        XCTAssertTrue(BattyScreen.element("server-pane-stop", in: app).exists)
        _ = BattyCLI.run(["pane", "close", "--pane", terminalID.uuidString])
    }

    @MainActor
    func testServerVerbsAbsentWithFlagForcedOff() throws {
        let (app, session) = try launch(extraEnvironment: ["BATTY_UI_TEST_FORCE_SERVER_PANE_OFF": "1"])
        defer { app.terminate() }
        // Never bound: the verb is refused before anything runs.
        let port = 59_999
        let result = BattyCLI.run(["server", "start", "--port", String(port), "--pane", session.focusedPaneID.uuidString, "--"] + pythonServer(port))
        XCTAssertNotEqual(result.status, 0, result.summary)
        XCTAssertEqual(BattyCLI.topology()?.session(session.id)?.panes.count, session.panes.count, "a flag-off server start changed the layout")
    }
}
