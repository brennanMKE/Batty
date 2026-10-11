// CLIReadVerbTests.swift

import XCTest

/// `list` scopes, `--include-dimensions`, `session info` without a target,
/// and `pane split` without `--pane` (#0447). Every call goes through the
/// relay, which carries no `BATTY_*` environment, so the no-target cases
/// exercise the app's focused-element fallback.
nonisolated final class CLIReadVerbTests: XCTestCase {
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

    private func split(_ flag: String, of paneID: UUID, extra: [String] = []) throws -> UUID {
        let result = BattyCLI.runExpectingSuccess(["pane", "split", flag, "--pane", paneID.uuidString] + extra)
        return try XCTUnwrap(result.ids.last, "pane split printed no id: \(result.summary)")
    }

    /// Text after the closing quote of a quoted title: the flags and cwd.
    private func tokensAfterTitle(_ line: String) -> [Substring] {
        line.split(separator: "\"", omittingEmptySubsequences: false).last?.split(separator: " ") ?? []
    }

    // MARK: - A.5 list sessions / tabs

    @MainActor
    func testListSessionsAndTabsPrintEveryRecord() throws {
        let (app, _, initial) = try BattyCLI.launchConnected(from: Self.self)
        defer { app.terminate() }

        let first = try XCTUnwrap(initial.selectedSession)
        _ = try split("-h", of: first.focusedPaneID)
        BattyCLI.runExpectingSuccess(["pane", "focus", first.focusedPaneID.uuidString])
        app.typeKey("t", modifierFlags: [.command])
        _ = try BattyCLI.newSession(at: try makeDirectory("list-scopes-project"))
        BattyCLI.runExpectingSuccess(["session", "focus", first.id.uuidString])
        let topology = try XCTUnwrap(BattyCLI.waitForTopology {
            $0.sessions.count == initial.sessions.count + 1
                && $0.selectedSessionID == first.id
                && $0.session(first.id)?.panes.count == 2
                && ($0.session(first.id)?.panes.reduce(0) { $0 + $1.tabIDs.count } ?? 0) == 3
        }, "the fixture (two Sessions, one with two Panes and a second Tab) never settled")

        // `sessions` is the default scope.
        let byDefault = BattyCLI.runExpectingSuccess(["list"])
        let explicit = BattyCLI.runExpectingSuccess(["list", "sessions"])
        XCTAssertEqual(byDefault.lines, explicit.lines, "list with no scope must equal list sessions")
        XCTAssertEqual(explicit.lines.count, topology.sessions.count)
        for session in topology.sessions {
            let line = try XCTUnwrap(explicit.lines.first { $0.hasPrefix("session \(session.id.uuidString) ") }, "list sessions is missing \(session.id)")
            XCTAssertTrue(line.contains("\"\(session.name)\""), line)
            XCTAssertTrue(line.contains("panes=\(session.panes.count)"), line)
            XCTAssertEqual(line.split(separator: " ").contains("active"), session.id == topology.selectedSessionID, "only the selected Session is active: \(line)")
        }
        XCTAssertFalse(explicit.lines.contains { $0.hasPrefix("pane ") || $0.hasPrefix("tab ") }, "list sessions leaked other scopes")

        let tabs = BattyCLI.runExpectingSuccess(["list", "tabs"])
        let expectedTabs = topology.sessions.flatMap { session in session.panes.flatMap { pane in pane.tabIDs.map { (session, pane, $0) } } }
        XCTAssertEqual(tabs.lines.count, expectedTabs.count)
        XCTAssertGreaterThan(expectedTabs.filter { $0.1.activeTabID != $0.2 }.count, 0, "fixture needs an inactive Tab for the active flag to prove anything")
        for (session, pane, tabID) in expectedTabs {
            let line = try XCTUnwrap(tabs.lines.first { $0.hasPrefix("tab \(tabID.uuidString) ") }, "list tabs is missing \(tabID)")
            XCTAssertTrue(line.contains("pane=\(pane.id.uuidString)") && line.contains("session=\(session.id.uuidString)"), line)
            XCTAssertEqual(tokensAfterTitle(line).contains("active"), pane.activeTabID == tabID, "active flag on \(line)")
        }
    }

    // MARK: - A.6 session info with no --session

    @MainActor
    func testSessionInfoWithoutFlagReportsTheFocusedSession() throws {
        let (app, _, initial) = try BattyCLI.launchConnected(from: Self.self)
        defer { app.terminate() }

        let first = try XCTUnwrap(initial.selectedSession)
        let (second, _) = try BattyCLI.newSession(at: try makeDirectory("session-info-project"))

        for target in [first.id, second.id, first.id] {
            BattyCLI.runExpectingSuccess(["session", "focus", target.uuidString])
            _ = try XCTUnwrap(BattyCLI.waitForTopology { $0.selectedSessionID == target })
            let json = BattyCLI.runExpectingSuccess(["session", "info", "--json"])
            let decoded = try XCTUnwrap(CLITopology(sessionInfoOutput: json.output), "session info --json was not a Session: \(json.output)")
            XCTAssertEqual(decoded.sessions.first?.id, target, "session info with no flag must report the focused Session")
            XCTAssertEqual(decoded.sessions.first?.isActive, true)

            let plain = BattyCLI.runExpectingSuccess(["session", "info"])
            XCTAssertTrue(plain.lines.first?.hasPrefix("session \(target.uuidString) ") ?? false, "plain session info: \(plain.output)")
        }
    }

    // MARK: - A.4 --include-dimensions

    @MainActor
    func testIncludeDimensionsReportsFramesOfVisiblePanes() throws {
        let (app, _, initial) = try BattyCLI.launchConnected(from: Self.self)
        defer { app.terminate() }

        let session = try XCTUnwrap(initial.selectedSession)
        let left = session.focusedPaneID
        let right = try split("-h", of: left)
        let below = try split("-v", of: right)
        let hidden = try split("-h", of: left)
        BattyCLI.runExpectingSuccess(["pane", "hide", "--pane", hidden.uuidString])
        let view = BattyCLI.runExpectingSuccess(["pane", "split", "--view", "system-metrics", "--pane", left.uuidString]).ids.last
        _ = try XCTUnwrap(view)
        let settled = try XCTUnwrap(BattyCLI.waitForTopology { $0.session(session.id)?.panes.count == 5 && $0.pane(hidden)?.isHidden == true })
        for id in [left, right, below] {
            XCTAssertTrue(BattyScreen.terminalPane(id, in: app).waitForExistence(timeout: 10))
        }
        BattyScreen.expectMatches(settled, in: app)

        // Without the flag no Pane reports a frame.
        XCTAssertTrue(settled.sessions.allSatisfy { $0.panes.allSatisfy { $0.frame == nil } }, "frames must be absent without --include-dimensions")

        let withDimensions = try XCTUnwrap(BattyCLI.topology(includeDimensions: true))
        for id in [left, right, below] {
            let frame = try XCTUnwrap(withDimensions.pane(id)?.frame, "visible Pane \(id) reports no frame")
            let anchor = BattyScreen.terminalPane(id, in: app).frame
            XCTAssertGreaterThan(frame.width, 1)
            XCTAssertGreaterThan(frame.height, 1)
            XCTAssertEqual(frame.width, anchor.width, accuracy: max(8, anchor.width * 0.05), "frame width disagrees with the on-screen Pane \(id)")
            XCTAssertEqual(frame.height, anchor.height, accuracy: max(8, anchor.height * 0.05), "frame height disagrees with the on-screen Pane \(id)")
        }
        let widths = [left, right, below].compactMap { withDimensions.pane($0)?.frame?.size }
        XCTAssertGreaterThan(Set(widths.map { "\($0.width)x\($0.height)" }).count, 1, "distinct Panes should not all report one size")
        XCTAssertNil(withDimensions.pane(try XCTUnwrap(view))?.frame, "a view Pane has no terminal surface, so no frame")
        XCTAssertNil(withDimensions.pane(hidden)?.frame, "a hidden Pane is not laid out, so it reports no frame")

        // The plain-text printers add `frame=` for terminal Panes only when asked.
        let without = BattyCLI.runExpectingSuccess(["list", "panes"])
        XCTAssertFalse(without.output.contains("frame="))
        let plain = BattyCLI.runExpectingSuccess(["list", "panes", "--include-dimensions"])
        for id in [left, right, below] {
            let line = try XCTUnwrap(plain.lines.first { $0.hasPrefix("pane \(id.uuidString) ") })
            let frame = try XCTUnwrap(withDimensions.pane(id)?.frame)
            XCTAssertTrue(line.contains("frame=\(Int(frame.minX)),\(Int(frame.minY)),\(Int(frame.width))x\(Int(frame.height))"), "plain frame disagrees with JSON: \(line)")
        }

        let info = BattyCLI.runExpectingSuccess(["session", "info", "--session", session.id.uuidString, "--include-dimensions", "--json"])
        let decoded = try XCTUnwrap(CLITopology(sessionInfoOutput: info.output))
        XCTAssertEqual(decoded.sessions.first?.pane(left)?.frame, withDimensions.pane(left)?.frame)
        let infoWithout = BattyCLI.runExpectingSuccess(["session", "info", "--session", session.id.uuidString, "--json"])
        XCTAssertNil(CLITopology(sessionInfoOutput: infoWithout.output)?.sessions.first?.pane(left)?.frame)
        let infoPlain = BattyCLI.runExpectingSuccess(["session", "info", "--session", session.id.uuidString, "--include-dimensions"])
        XCTAssertTrue(infoPlain.lines.contains { $0.hasPrefix("pane \(left.uuidString) ") && $0.contains("frame=") }, infoPlain.output)
    }

    // MARK: - A.8 pane split with no --pane

    @MainActor
    func testSplitWithoutPaneSplitsTheFocusedPane() throws {
        let (app, _, initial) = try BattyCLI.launchConnected(from: Self.self)
        defer { app.terminate() }

        let session = try XCTUnwrap(initial.selectedSession)
        let first = session.focusedPaneID
        let second = try split("-h", of: first)
        XCTAssertTrue(BattyScreen.terminalPane(second, in: app).waitForExistence(timeout: 10))
        // The focused Pane is the second one, not the first the fallback might
        // otherwise pick.
        BattyCLI.runExpectingSuccess(["pane", "focus", second.uuidString])
        _ = try XCTUnwrap(BattyCLI.waitForTopology { $0.session(session.id)?.focusedPaneID == second })

        let result = BattyCLI.runExpectingSuccess(["pane", "split", "-v"])
        let third = try XCTUnwrap(result.ids.last, "pane split printed no id: \(result.summary)")
        let topology = try XCTUnwrap(BattyCLI.waitForTopology { $0.session(session.id)?.pane(third) != nil })
        XCTAssertEqual(topology.session(session.id)?.panes.count, 3)
        XCTAssertTrue(BattyScreen.terminalPane(third, in: app).waitForExistence(timeout: 10))

        let secondFrame = BattyScreen.terminalPane(second, in: app).frame
        let thirdFrame = BattyScreen.terminalPane(third, in: app).frame
        XCTAssertTrue(
            waitFor({
                let b = BattyScreen.terminalPane(second, in: app).frame
                let c = BattyScreen.terminalPane(third, in: app).frame
                return b.maxY <= c.minY + 4 && abs(b.minX - c.minX) <= 4
            }, timeout: 10),
            "the new Pane must be stacked under the focused (second) Pane: \(secondFrame) vs \(thirdFrame)"
        )
        let firstFrame = BattyScreen.terminalPane(first, in: app).frame
        XCTAssertGreaterThan(firstFrame.height, thirdFrame.height * 1.5, "the first Pane must keep its full height, only the focused one was split")
        BattyScreen.expectMatches(topology, in: app)
    }
}
