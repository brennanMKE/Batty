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

        // Live under NSTemporaryDirectory(), not a hard-coded /tmp path: the
        // XCUITest runner is sandboxed and can't write directly into /tmp,
        // so its own temp directory is a location both it and the
        // unsandboxed app under test can reach. The typed `cd` command
        // carries the literal absolute path, so the app process never needs
        // to resolve NSTemporaryDirectory() itself.
        let unique = UUID().uuidString.prefix(8)
        let tmp = NSTemporaryDirectory()
        projectDir = (tmp as NSString).appendingPathComponent("batty-uitest-proj-\(unique)")
        plainDir = (tmp as NSString).appendingPathComponent("batty-uitest-plain-\(unique)")
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
        // The command also reports $HOST (zsh's value, captured at shell
        // startup) alongside a live `hostname` call, via a sentinel file —
        // shell-integration's OSC 7 report embeds $HOST, and libghostty
        // rejects the pwd update outright if that host doesn't match a
        // live hostname lookup at report time (`internal_os.hostname.isLocal`
        // in ghostty-upstream's `termio/stream_handler.zig`). The sentinel
        // also independently proves the shell actually reached the
        // directory (the `&&` only fires on a successful `cd`), separating
        // a fixture-reachability regression from a rename-pipeline one.
        let hostCheckSentinel = BattyUITestHarness.sentinelPath(named: "cd-host-check")
        app.typeText("cd \(projectDir) && printf 'HOST=%s LIVEHOST=%s\\n' \"$HOST\" \"$(hostname)\" > \(hostCheckSentinel)\n")
        XCTAssertTrue(
            BattyUITestHarness.waitForFile(at: hostCheckSentinel, timeout: 5),
            "Shell did not finish cd into the project dir"
        )
        let hostCheckReport = (try? String(contentsOfFile: hostCheckSentinel, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "<sentinel unreadable>"
        let renamed = waitFor({ BattyUITestHarness.sessionRow(named: projectName, in: app).exists },
                               timeout: 10)
        if !renamed {
            // On failure only, so a passing run's log stays quiet: the
            // window title mirrors `session.title` through a wholly
            // separate SwiftUI binding (`SessionDetailView.navigationTitle`)
            // than the sidebar row's accessibility identifier this test
            // polls — a mismatch between the two tells a model-level miss
            // apart from a sidebar-rendering-only one.
            let windowTitle = app.windows.firstMatch.title
            XCTFail(
                "Session should rename to '\(projectName)' after cd into the project dir " +
                "(shell reported: \(hostCheckReport); window title: '\(windowTitle)')"
            )
        }

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
