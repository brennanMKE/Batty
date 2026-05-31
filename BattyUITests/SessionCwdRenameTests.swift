// SessionCwdRenameTests.swift

import XCTest

/// Live-update auto-naming regression suite for [[0227]].
///
/// [[0213]] made a single-pane session's name track the shell's cwd, but the
/// signal was consumed through a SwiftUI `.onChange` over a Combine-backed
/// `workingDirectory`, which fired only on incidental re-renders — so a plain
/// `cd` left the name stuck on the initial directory. [[0227]] rewired it to
/// libghostty's pwd delegate. This test drives a real `cd` in the terminal and
/// asserts the sidebar session row renames into a project and resets back out,
/// which the BattyKit model unit tests cannot cover (the defect was in the
/// view→delegate wiring, not the store).
nonisolated final class SessionCwdRenameTests: XCTestCase {

    /// Directory containing a `package.json` so `ProjectNameResolver` resolves
    /// it to a known name (the node rule reads the JSON `name` field, so the
    /// resolved title is independent of the directory's own basename).
    private var projectDir = ""
    /// Plain directory with no project marker — cd'ing here must reset the name.
    private var plainDir = ""

    private let projectName = "BattyCdProbe"

    override func setUpWithError() throws {
        continueAfterFailure = false
        BattyUITestHarness.sweepSentinels()

        // Live under /tmp (not NSTemporaryDirectory) so the unsandboxed app
        // process resolves the same absolute paths the terminal cd's into.
        let unique = UUID().uuidString.prefix(8)
        projectDir = "/tmp/batty-uitest-proj-\(unique)"
        plainDir = "/tmp/batty-uitest-plain-\(unique)"
        let fm = FileManager.default
        try fm.createDirectory(atPath: projectDir, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: plainDir, withIntermediateDirectories: true)
        try #"{"name":"\#(projectName)"}"#
            .write(toFile: "\(projectDir)/package.json", atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        BattyUITestHarness.sweepSentinels()
        let fm = FileManager.default
        try? fm.removeItem(atPath: projectDir)
        try? fm.removeItem(atPath: plainDir)
    }

    /// cd into a project folder renames the session to the project name;
    /// cd out to a plain folder resets it to the default `Session N`.
    /// Would have caught [[0227]]: the name stayed stuck after `cd`.
    @MainActor
    func testSessionNameTracksCdIntoAndOutOfProjectDir() throws {
        // Local copies so the escaping waitFor / autoclosure assertions below
        // don't need explicit self capture.
        let projectName = projectName
        let projectDir = projectDir
        let plainDir = plainDir

        let app = BattyUITestHarness.launchBatty()
        defer { app.terminate() }

        XCTAssertNil(BattyUITestHarness.waitForDriverErrors(), "Driver script failed")
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        // The launch session starts in the temp home (not a project): "Session 1".
        let initialRow = BattyUITestHarness.sessionRow(named: "Session 1", in: app)
        XCTAssertTrue(initialRow.waitForExistence(timeout: 10),
                      "Launch session should be named 'Session 1'")

        // Focus the terminal so typed text reaches the shell.
        let pane = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'pane-terminal.'"))
            .firstMatch
        XCTAssertTrue(pane.waitForExistence(timeout: 5))
        pane.click()
        pause(0.5)

        // cd INTO the project dir: the session should rename to the project name.
        app.typeText("cd \(projectDir)\n")
        XCTAssertTrue(
            waitFor({ BattyUITestHarness.sessionRow(named: projectName, in: app).exists },
                    timeout: 10),
            "Session should rename to '\(projectName)' after cd into the project dir"
        )

        // cd OUT to a plain dir: the name must drop the project name and reset.
        app.typeText("cd \(plainDir)\n")
        XCTAssertTrue(
            waitFor({ BattyUITestHarness.sessionRow(named: "Session 1", in: app).exists },
                    timeout: 10),
            "Session should reset to 'Session 1' after cd out to a non-project dir ([[0227]] regression)"
        )
        XCTAssertFalse(
            BattyUITestHarness.sessionRow(named: projectName, in: app).exists,
            "Stale project name must not remain after leaving the project dir"
        )
    }
}
