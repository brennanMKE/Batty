// ProjectsCLITests.swift

import XCTest

/// `batty project list` and `batty project open` against the real app
/// (#0478, covering #0477), through the guest relay `BattyCLI` uses. The
/// Prod half (no `project` noun) is compile-time and covered by #0477's
/// unit tests; the VM runs the Beta build.
nonisolated final class ProjectsCLITests: ProjectsUITestCase {
    private struct Entry {
        let name: String
        let paneCount: Int
        let isOpen: Bool
    }

    private func list() throws -> [Entry] {
        let result = BattyCLI.runExpectingSuccess(["project", "list", "--json"])
        let object = try XCTUnwrap(CLITopology.jsonObject(in: result.output), "project list --json was not JSON: \(result.summary)")
        let entries = try XCTUnwrap(object["projects"] as? [[String: Any]])
        return entries.map {
            Entry(
                name: $0["name"] as? String ?? "",
                paneCount: ($0["paneCount"] as? NSNumber)?.intValue ?? -1,
                isOpen: $0["isOpen"] as? Bool ?? false
            )
        }
    }

    @MainActor
    func testProjectListShowsSeededProjectsAndOpenMarker() throws {
        let alpha = ProjectFixture.project(
            name: "Alpha Stack",
            root: try makeDirectory("alpha"),
            layout: ProjectFixture.split("horizontal", [ProjectFixture.terminal(), ProjectFixture.view("system-metrics")]),
            preset: "horizontalSplit",
            lastOpenedAt: "2026-01-02T00:00:00Z"
        )
        let beta = ProjectFixture.project(name: "Beta Duo", root: try makeDirectory("beta"), layout: ProjectFixture.terminal(), preset: "singlePane", lastOpenedAt: "2026-01-01T00:00:00Z")
        let (app, _) = try launchApp(projects: [alpha, beta])
        defer { app.terminate() }

        var entries = try list()
        XCTAssertEqual(entries.map(\.name), ["Alpha Stack", "Beta Duo"], "seeded dates agree with store order")
        XCTAssertEqual(entries.map(\.paneCount), [2, 1])
        XCTAssertEqual(entries.map(\.isOpen), [false, false])

        let text = BattyCLI.runExpectingSuccess(["project", "list"])
        XCTAssertTrue(text.output.contains("Alpha Stack") && text.output.contains("Beta Duo"), "the table omits a Project: \(text.output)")

        let opened = BattyCLI.runExpectingSuccess(["project", "open", "Alpha Stack"])
        XCTAssertTrue(opened.output.contains("Opened Session \"Alpha Stack\""), opened.summary)
        let session = try XCTUnwrap(waitForSessions(named: "Alpha Stack").first)
        XCTAssertTrue(BattyUITestHarness.sessionRow(named: "Alpha Stack", in: app).waitForExistence(timeout: 10))

        entries = try list()
        XCTAssertEqual(entries.map(\.name), ["Beta Duo", "Alpha Stack"], "the open Project, first in store order, sinks below the closed one")
        XCTAssertEqual(entries.map(\.isOpen), [false, true], "only the opened Project carries the open marker")
        let marked = BattyCLI.runExpectingSuccess(["project", "list"])
        let alphaLine = try XCTUnwrap(marked.lines.first { $0.hasPrefix("Alpha Stack") })
        XCTAssertTrue(alphaLine.hasSuffix("open"), "the table does not mark the open Project: \(marked.output)")
        XCTAssertFalse(try XCTUnwrap(marked.lines.first { $0.hasPrefix("Beta Duo") }).hasSuffix("open"))

        let focused = BattyCLI.runExpectingSuccess(["project", "open", "alpha stack"])
        XCTAssertTrue(focused.output.contains("Focused Session \"Alpha Stack\""), "a second open found no existing Session: \(focused.summary)")
        XCTAssertEqual(BattyCLI.topology()?.sessions.filter { $0.name == "Alpha Stack" }.count, 1)

        let another = BattyCLI.runExpectingSuccess(["project", "open", "Alpha Stack", "--new", "--json"])
        let json = try XCTUnwrap(CLITopology.jsonObject(in: another.output))
        XCTAssertEqual(json["created"] as? Bool, true)
        let copyID = try XCTUnwrap((json["sessionID"] as? String).flatMap(UUID.init(uuidString:)))
        XCTAssertNotEqual(copyID, session.id)
        XCTAssertNotNil(BattyCLI.waitForTopology { $0.session(copyID) != nil })

        let unknown = BattyCLI.run(["project", "open", "No Such Project"])
        XCTAssertNotEqual(unknown.status, 0, "opening an unknown Project succeeded: \(unknown.summary)")
    }
}
