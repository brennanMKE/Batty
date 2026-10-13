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
            preset: "horizontalSplit"
        )
        let beta = ProjectFixture.project(name: "Beta Duo", root: try makeDirectory("beta"), layout: ProjectFixture.terminal(), preset: "singlePane")
        let (app, _) = try launchApp(projects: [alpha, beta])
        defer { app.terminate() }

        var entries = try list()
        XCTAssertEqual(entries.map(\.name), ["Alpha Stack", "Beta Duo"])
        XCTAssertEqual(entries.map(\.paneCount), [2, 1])
        XCTAssertEqual(entries.map(\.isOpen), [false, false])

        let text = BattyCLI.runExpectingSuccess(["project", "list"])
        XCTAssertTrue(text.output.contains("Alpha Stack") && text.output.contains("Beta Duo"), "the table omits a Project: \(text.output)")

        let opened = BattyCLI.runExpectingSuccess(["project", "open", "Beta Duo"])
        XCTAssertTrue(opened.output.contains("Opened Session \"Beta Duo\""), opened.summary)
        let session = try XCTUnwrap(waitForSessions(named: "Beta Duo").first)
        XCTAssertTrue(BattyUITestHarness.sessionRow(named: "Beta Duo", in: app).waitForExistence(timeout: 10))

        entries = try list()
        XCTAssertEqual(entries.map(\.isOpen), [false, true], "only the opened Project carries the open marker")
        let marked = BattyCLI.runExpectingSuccess(["project", "list"])
        let betaLine = try XCTUnwrap(marked.lines.first { $0.hasPrefix("Beta Duo") })
        XCTAssertTrue(betaLine.hasSuffix("open"), "the table does not mark the open Project: \(marked.output)")
        XCTAssertFalse(try XCTUnwrap(marked.lines.first { $0.hasPrefix("Alpha Stack") }).hasSuffix("open"))

        let focused = BattyCLI.runExpectingSuccess(["project", "open", "beta duo"])
        XCTAssertTrue(focused.output.contains("Focused Session \"Beta Duo\""), "a second open found no existing Session: \(focused.summary)")
        XCTAssertEqual(BattyCLI.topology()?.sessions.filter { $0.name == "Beta Duo" }.count, 1)

        let another = BattyCLI.runExpectingSuccess(["project", "open", "Beta Duo", "--new", "--json"])
        let json = try XCTUnwrap(CLITopology.jsonObject(in: another.output))
        XCTAssertEqual(json["created"] as? Bool, true)
        let copyID = try XCTUnwrap((json["sessionID"] as? String).flatMap(UUID.init(uuidString:)))
        XCTAssertNotEqual(copyID, session.id)
        XCTAssertNotNil(BattyCLI.waitForTopology { $0.session(copyID) != nil })

        let unknown = BattyCLI.run(["project", "open", "No Such Project"])
        XCTAssertNotEqual(unknown.status, 0, "opening an unknown Project succeeded: \(unknown.summary)")
    }
}
