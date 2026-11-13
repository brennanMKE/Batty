// DemoSceneTests.swift

import XCTest

/// The nine website demo clips (#0505), one scene per test. Each scene drives
/// the real app inside the Tart VM while XCTest records the screen, and writes
/// a cue sheet (`demo.<clip>.cues.json`, attached with `.keepAlways`) so the
/// host-side edit (`tools/demo/DemoCut`) trims, speeds up and overlays by
/// cue, not by hard-coded timestamps.
///
/// On request only: it skips unless `tools/run-ui-tests-vm.sh` ran in demo
/// mode (`BATTY_UI_DEMO=1`) with a filter naming this class, which exports
/// `BATTY_UI_DEMO=1` to the runner. It also skips outside the Tart VM. The
/// repositories and tools it uses come from `tools/demo/guest-setup.sh`.
///
/// Pacing lives here (short holds so a viewer can read the result of a step);
/// dead time is cut in the edit. Long waits are bracketed with
/// `speedStart` / `speedEnd` cues and are recorded at real speed.
nonisolated final class DemoSceneTests: ProjectsUITestCase {
    private var origin = Date()
    private var clip = "scene"
    private var cues: [[String: Any]] = []
    private var notes: [String] = []
    private var preexec = ""

    /// The guest starts in Light. Every scene runs Dark, so the Sidebar, chrome and view
    /// Panes match the dark terminal Themes. Set once per run, through System Settings
    /// (`defaults write -g AppleInterfaceStyle` does not darken the app in the guest).
    nonisolated(unsafe) private static var guestIsDark = false

    private static var isVirtualMachine: Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("kern.hv_vmm_present", &value, &size, nil, 0) == 0 && value == 1
    }

    private static let home: String = {
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir { return String(cString: dir) }
        return "/Users/admin"
    }()

    override func setUpWithError() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["BATTY_UI_DEMO"] == "1",
            "DemoSceneTests runs on request only: BATTY_UI_DEMO=1 tools/run-ui-tests-vm.sh BattyUITests/DemoSceneTests"
        )
        try XCTSkipUnless(Self.isVirtualMachine, "DemoSceneTests drives a whole desktop; run it in the Tart VM only")
        try super.setUpWithError()
        origin = Date()
        cues = []
        notes = []
        if !Self.guestIsDark {
            let scratch = try XCTUnwrap(scratch)
            try MainActor.assumeIsolated { try Self.makeGuestDark(scratch: scratch) }
            Self.guestIsDark = true
        }
    }

    @MainActor
    private static func makeGuestDark(scratch: URL) throws {
        let app = BattyUITestHarness.launchBatty()
        defer { app.terminate() }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        let (_, initial) = try BattyCLI.connect(to: app, from: DemoSceneTests.self)
        let session = try XCTUnwrap(initial.selectedSession)
        let command = try BattyCLI.makeScript(
            in: scratch,
            named: "open-appearance-settings.sh",
            body: "open 'x-apple.systempreferences:com.apple.Appearance-Settings.extension'"
        )
        let scriptPane = try XCTUnwrap(BattyCLI.runExpectingSuccess(["pane", "split", "--pane", session.focusedPaneID.uuidString, "--command", command]).ids.last)
        let settings = XCUIApplication(bundleIdentifier: "com.apple.systempreferences")
        XCTAssertTrue(settings.windows.firstMatch.waitForExistence(timeout: 30), "System Settings did not open")
        let choice = settings.descendants(matching: .any).matching(NSPredicate(format: "label == 'Dark' OR title == 'Dark'")).firstMatch
        XCTAssertTrue(choice.waitForExistence(timeout: 15), "no Dark control in System Settings > Appearance")
        choice.click()
        BattyCLI.runExpectingSuccess(["pane", "close", "--pane", scriptPane.uuidString])
        BattyUITestHarness.pause(2)
        settings.terminate()
    }

    override func tearDownWithError() throws {
        if !cues.isEmpty {
            let sheet: [String: Any] = ["clip": clip, "duration": now, "cues": cues, "notes": notes]
            if let data = try? JSONSerialization.data(withJSONObject: sheet, options: [.prettyPrinted, .sortedKeys]) {
                let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
                attachment.name = "demo.\(clip).cues.json"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
        try super.tearDownWithError()
    }

    // MARK: - Cues and pacing

    private var now: Double { Date().timeIntervalSince(origin) }

    /// `kind` is one of `start`, `end`, `poster`, `callout`, `speedStart`, `speedEnd`.
    private func mark(_ id: String, _ kind: String = "callout") {
        cues.append(["t": now, "kind": kind, "id": id])
    }

    private func note(_ text: String) {
        notes.append("\(String(format: "%.1f", now))s \(text)")
    }

    /// Zoom the edit in on `frame` (screen points, so the same as recording pixels) until `zoomOut`.
    /// The rect is widened to 16:9, at least `width` wide, and kept on screen.
    private func zoomIn(_ id: String, around frame: CGRect, width: CGFloat = 760) {
        let w = max(width, frame.width * 1.15)
        let h = w * 9 / 16
        let x = min(max(0, frame.midX - w / 2), 1920 - w)
        let y = min(max(0, frame.midY - h / 2), 1080 - h)
        cues.append(["t": now, "kind": "zoomStart", "id": id, "rect": [x, y, w, h]])
    }

    private func zoomOut(_ id: String) {
        cues.append(["t": now, "kind": "zoomEnd", "id": id])
    }

    private func beat(_ seconds: Double = 0.8) {
        BattyUITestHarness.pause(seconds)
    }

    private func repo(_ slug: String) -> URL {
        URL(filePath: Self.home).appending(path: "Developer/\(slug)")
    }

    // MARK: - Scene plumbing

    /// Launches Batty with `projects` and `script`, fills the display, clears
    /// the guest's banners and connects the CLI. Everything before the
    /// scene's `start` cue is trimmed away.
    @MainActor
    private func launchScene(_ name: String, projects: [[String: Any]]? = nil, theme: String? = "Adventure Time", environment: [String: String] = [:]) throws -> XCUIApplication {
        clip = name
        preexec = BattyUITestHarness.sentinelPath(named: "preexec")
        var script: [[String: Any]] = []
        if let theme { script.append(["intent": "applyTheme", "name": theme]) }
        let (app, _) = try launchApp(projects: projects ?? [], script: script, extraEnvironment: environment.merging(["DEMO_PREEXEC_FILE": preexec]) { current, _ in current })
        dismissBanners()
        zoomWindow(in: app)
        return app
    }

    @MainActor
    private func zoomWindow(in app: XCUIApplication) {
        let window = app.menuBars.firstMatch.menuBarItems["Window"]
        guard window.waitForExistence(timeout: 5) else { return note("no Window menu") }
        window.click()
        let zoom = window.menus.firstMatch.menuItems["Zoom"]
        if zoom.waitForExistence(timeout: 3) { zoom.click() } else { closeMenus(app) }
        _ = waitFor({ app.windows.firstMatch.frame.width > 1500 }, timeout: 5)
        note("window \(Int(app.windows.firstMatch.frame.width))x\(Int(app.windows.firstMatch.frame.height))")
    }

    /// A Session in the clone, once the Sidebar has named it from its folder or branch.
    private func newSession(_ slug: String) throws -> (session: CLITopology.Session, paneID: UUID) {
        let created = try BattyCLI.newSession(at: repo(slug))
        let named = BattyCLI.waitForTopology(timeout: 15) { topology in
            guard let name = topology.session(created.session.id)?.name else { return false }
            return name.range(of: #"^Session \d+$"#, options: .regularExpression) == nil
        }
        if let session = named?.session(created.session.id) { return (session, created.paneID) }
        note("Session \(created.session.name) kept its default name")
        return created
    }

    /// Types `text` and Return into whatever has keyboard focus, then waits for the shell's
    /// preexec hook to report the line was submitted (typing into a terminal lags the call).
    @MainActor
    private func submit(_ text: String, in app: XCUIApplication) {
        try? FileManager.default.removeItem(atPath: preexec)
        app.typeText(text)
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
        if !waitFor({ FileManager.default.fileExists(atPath: self.preexec) }, timeout: 20) {
            note("no preexec signal for: \(text)")
        }
    }

    /// Types `command` into the Pane's terminal and presses Return.
    @MainActor
    private func run(_ command: String, pane: UUID, app: XCUIApplication) {
        let terminal = BattyScreen.terminalPane(pane, in: app)
        XCTAssertTrue(terminal.waitForExistence(timeout: 10), "no terminal for Pane \(pane)")
        terminal.click()
        submit(command, in: app)
    }

    /// Opens a Git Status group (they start collapsed) by clicking its disclosure arrow, at the
    /// leading edge of the group's row, then waits for `row` to appear.
    @MainActor
    private func expandGitGroup(_ prefix: String, until row: String, in app: XCUIApplication) {
        let header = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 15), "Git Status never listed \(prefix)")
        for dx in [CGFloat(10), 22, 36] {
            if element(row, in: app).exists { return }
            header.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: dx, dy: header.frame.height / 2)).click()
            if element(row, in: app).waitForExistence(timeout: 3) { return }
        }
    }

    @MainActor
    private func chord(_ character: String, _ flags: XCUIElement.KeyModifierFlags, in app: XCUIApplication) {
        app.typeKey(character, modifierFlags: flags)
    }

    @MainActor
    private func key(_ key: XCUIKeyboardKey, _ flags: XCUIElement.KeyModifierFlags = [], in app: XCUIApplication) {
        app.typeKey(key.rawValue, modifierFlags: flags)
    }

    @MainActor
    private func selectedSession() -> CLITopology.Session? {
        BattyCLI.topology()?.selectedSession
    }

    @MainActor
    private func terminalPanes(in app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'pane-terminal.'"))
    }

    /// A real Project record for a clone under `~/Developer`.
    private func project(_ name: String, slug: String, layout: [String: Any], startup: Bool = false, symbol: String? = nil, color: Int = 0) -> [String: Any] {
        ProjectFixture.project(name: name, root: repo(slug), layout: layout, runStartupCommands: startup, symbol: symbol, color: color)
    }

    /// The four demo Projects, each with its own palette color and symbol. AWS carries
    /// `heroLayout`; the others are small. Colors are `SessionColor` indexes, because a
    /// Session takes only the palette index when its Project opens.
    private func demoProjects(heroLayout: [String: Any]? = nil, simple: Bool = false) -> [[String: Any]] {
        let one = ProjectFixture.terminal()
        return [
            project("AWS", slug: "demo/aws-infra", layout: heroLayout ?? one, symbol: "cloud", color: 1),
            project("Home Assistant", slug: "demo/home-assistant", layout: simple ? one : ProjectFixture.split("horizontal", [
                ProjectFixture.terminal([ProjectFixture.tab("Config")]), ProjectFixture.terminal([ProjectFixture.tab("Logs")]),
            ]), symbol: "home", color: 8),
            project("Music", slug: "demo/music-app", layout: simple ? one : ProjectFixture.split("vertical", [
                ProjectFixture.terminal(), ProjectFixture.terminal(),
            ]), symbol: "music", color: 6),
            project("Batty", slug: "brennanMKE/Batty", layout: simple ? one : ProjectFixture.terminal([ProjectFixture.tab("Editor")]), symbol: "terminal", color: 2),
        ]
    }

    // Every clip is 15 s or less: all setup (Sessions, repos, builds, shells) happens before the
    // `start` cue, and the part after it is the feature and nothing else. Beats are a few tenths
    // of a second. Typing is the feature only in clip 09, and it is sped up in the edit.

    // MARK: - 01 Projects

    @MainActor
    func testClip01Projects() throws {
        let projects = demoProjects(heroLayout: ProjectFixture.split("horizontal", [
            ProjectFixture.terminal([ProjectFixture.tab("Shell"), ProjectFixture.tab("Tests")]),
            ProjectFixture.split("vertical", [
                ProjectFixture.view("git-status", repository: "."),
                ProjectFixture.terminal([ProjectFixture.tab("Server")]),
            ]),
        ]))
        let app = try launchScene("01-projects", projects: projects)
        defer { app.terminate() }

        // Off camera: one Project is already open, so the Open now strip has a chip.
        click("session-sidebar.open-project-button", in: app)
        XCTAssertTrue(element("project-picker.root", in: app).waitForExistence(timeout: 10))
        filterPicker(to: "Music", in: app)
        pressReturn(in: app)
        _ = waitForSessions(named: "Music")
        waitForRowIcon("Music", "music.note", in: app)

        mark("start", "start")
        click("session-sidebar.open-project-button", in: app)
        XCTAssertTrue(element("project-picker.root", in: app).waitForExistence(timeout: 10), "the Open Project picker did not appear")
        mark("picker")
        zoomIn("picker", around: element("project-picker.root", in: app).frame, width: 1000)
        beat(0.5)
        let shared = element("project-picker.shared.AWS", in: app)
        XCTAssertTrue(shared.waitForExistence(timeout: 5), "no Shared checkbox on the AWS card")
        shared.click()
        XCTAssertTrue(waitFor({ self.isChecked(self.element("project-picker.shared.AWS", in: app)) }, timeout: 5), "Shared did not tick")
        mark("shared")
        beat(0.6)
        zoomOut("picker")
        filterPicker(to: "AWS", in: app)
        pressReturn(in: app)
        let aws = try XCTUnwrap(waitForSessions(named: "AWS").first)
        XCTAssertTrue(element("git-status.snapshot", in: app).waitForExistence(timeout: 20), "the Git Status Pane did not render")
        XCTAssertNotNil(BattyCLI.waitForTopology { $0.session(aws.id)?.visiblePanes.count == 3 }, "the Project did not open with three Panes")
        waitForRowIcon("AWS", "cloud.fill", in: app)
        mark("opened")
        mark("poster", "poster")
        beat(1.2)

        click("session-sidebar.open-project-button", in: app)
        XCTAssertTrue(element("project-picker.open-now", in: app).waitForExistence(timeout: 10), "no Open now strip")
        mark("opennow")
        beat(0.5)
        let chip = element("project-picker.card.AWS", in: app)
        XCTAssertTrue(chip.waitForExistence(timeout: 5), "no AWS chip")
        chip.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5)).click()
        mark("another")
        beat(0.4)
        pressReturn(in: app, option: true)
        XCTAssertEqual(waitForSessions(named: "AWS", count: 2).count, 2, "Option-Return did not open another copy")
        beat(1.0)
        mark("end", "end")
    }

    // MARK: - 02 Sessions and Sidebar

    @MainActor
    func testClip02SessionsAndSidebar() throws {
        let app = try launchScene("02-sessions", projects: demoProjects(simple: true))
        defer { app.terminate() }

        // Off camera: three Projects open between two plain repo Sessions, so the Sidebar mixes
        // Project symbols with plain circles. Set Color targets the plain Batty Session.
        var names: [String] = []
        let icons = ["AWS": "cloud.fill", "Home Assistant": "house.fill", "Music": "music.note"]
        for step in ["project:AWS", "brennanMKE/Batty", "project:Home Assistant", "neovim/neovim", "project:Music"] {
            if step.hasPrefix("project:") {
                let name = String(step.dropFirst("project:".count))
                let opened = BattyCLI.runExpectingSuccess(["project", "open", name, "--json"])
                let json = try XCTUnwrap(CLITopology.jsonObject(in: opened.output), "no JSON from project open \(name)")
                let id = try XCTUnwrap((json["sessionID"] as? String).flatMap(UUID.init(uuidString:)), "no sessionID for \(name)")
                let session = try XCTUnwrap(BattyCLI.waitForTopology { $0.session(id) != nil }?.session(id), "Project \(name) never opened")
                names.append(session.name)
                run("git status -sb", pane: session.focusedPaneID, app: app)
                waitForRowIcon(session.name, try XCTUnwrap(icons[name]), in: app)
            } else {
                let created = try newSession(step)
                names.append(created.session.name)
                run("git status -sb", pane: created.paneID, app: app)
            }
        }
        XCTAssertGreaterThanOrEqual(names.count, 5)
        note("sessions \(names)")
        app.typeKey("1", modifierFlags: .command)
        beat(0.8)

        mark("start", "start")
        mark("switch")
        let sidebar = BattyUITestHarness.sidebar(in: app).frame
        zoomIn("sidebar", around: CGRect(x: sidebar.minX, y: sidebar.minY + 20, width: 300, height: 130), width: 640)
        for number in ["2", "3", "4", "5", "3", "2", "4"] {
            app.typeKey(number, modifierFlags: .command)
            beat(0.28)
        }
        mark("poster", "poster")

        let colorRow = BattyUITestHarness.sessionRow(named: names[1], in: app)
        colorRow.rightClick()
        let color = app.menuItems.matching(NSPredicate(format: "title BEGINSWITH 'Set Color'")).firstMatch
        XCTAssertTrue(color.waitForExistence(timeout: 5), "no Set Color item")
        color.click()
        mark("color")
        for _ in 0..<3 { key(.rightArrow, in: app); beat(0.2) }
        key(.return, in: app)
        beat(0.5)

        let editor = BattyUITestHarness.sessionRow(named: names[4], in: app)
        let top = BattyUITestHarness.sessionRow(named: names[0], in: app)
        let before = BattyCLI.topology()?.sessions.map(\.name) ?? []
        mark("reorder")
        editor.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.4, thenDragTo: top.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)))
        beat(0.8)
        let after = BattyCLI.topology()?.sessions.map(\.name) ?? []
        zoomOut("sidebar")
        note("order before \(before) after \(after)")
        XCTAssertNotEqual(before, after, "the drag did not reorder the Sessions")
        mark("end", "end")
    }

    // MARK: - 03 Splits, Tabs and Layouts

    @MainActor
    func testClip03SplitsTabsLayouts() throws {
        let app = try launchScene("03-splits")
        defer { app.terminate() }

        let created = try newSession("brennanMKE/Batty")
        run("ls", pane: created.paneID, app: app)
        beat(0.5)

        mark("start", "start")
        chord("l", [.command, .shift], in: app)
        mark("layout")
        beat(0.5)
        let thumbnail = app.staticTexts["Main left, two right"].firstMatch
        XCTAssertTrue(thumbnail.waitForExistence(timeout: 5), "no Main left, two right layout")
        thumbnail.click()
        XCTAssertTrue(waitFor({ self.terminalPanes(in: app).count >= 3 }, timeout: 10), "the layout did not produce at least three Panes")
        beat(0.4)

        let panes = terminalPanes(in: app).allElementsBoundByIndex.sorted { $0.frame.minX < $1.frame.minX }
        let left = panes[0]
        let right = panes.dropFirst().filter { $0.frame.minX >= left.frame.maxX - 2 }.min { $0.frame.minX < $1.frame.minX } ?? panes[panes.count - 1]
        let window = app.windows.firstMatch
        let origin = window.coordinate(withNormalizedOffset: .zero)
        func at(_ x: CGFloat, _ y: CGFloat) -> XCUICoordinate {
            origin.withOffset(CGVector(dx: x - window.frame.minX, dy: y - window.frame.minY))
        }
        let dividerX = (left.frame.maxX + right.frame.minX) / 2
        let y = left.frame.midY
        let widthBefore = left.frame.width
        mark("divider")
        at(dividerX, y).press(forDuration: 0.2, thenDragTo: at(dividerX + 300, y))
        XCTAssertTrue(waitFor({ left.frame.width > widthBefore + 100 }, timeout: 5), "the divider did not move")
        beat(0.3)

        mark("tabs")
        let focusedPane = terminalPanes(in: app).allElementsBoundByIndex.first { ($0.value as? String) == "focused" } ?? left
        zoomIn("tabs", around: CGRect(x: focusedPane.frame.minX, y: focusedPane.frame.minY - 20, width: 400, height: 40), width: 720)
        for _ in 0..<2 {
            chord("t", .command, in: app)
            beat(0.35)
        }
        zoomOut("tabs")
        mark("poster", "poster")
        mark("split")
        let paneCount = terminalPanes(in: app).count
        chord("d", .command, in: app)
        XCTAssertTrue(waitFor({ self.terminalPanes(in: app).count == paneCount + 1 }, timeout: 10), "Cmd-D did not add a Pane")
        beat(0.4)
        mark("focus")
        for arrow in [XCUIKeyboardKey.rightArrow, .downArrow, .leftArrow, .upArrow] {
            key(arrow, [.command, .option], in: app)
            beat(0.3)
        }
        beat(0.4)
        mark("end", "end")
    }

    // MARK: - 04 Git Status

    @MainActor
    func testClip04GitStatus() throws {
        let app = try launchScene("04-git-status")
        defer { app.terminate() }

        let created = try newSession("brennanMKE/Batty")
        run("clear", pane: created.paneID, app: app)
        chord("g", .command, in: app)
        XCTAssertTrue(element("git-status.snapshot", in: app).waitForExistence(timeout: 15), "the Git Status Pane did not appear")
        run("nvim README.md", pane: created.paneID, app: app)
        beat(2.5)

        mark("start", "start")
        mark("edit")
        app.typeText("GoHello")
        key(.escape, in: app)
        app.typeText(":w")
        key(.return, in: app)
        let gitFrame = element("git-status.snapshot", in: app).frame
        zoomIn("rows", around: CGRect(x: gitFrame.minX, y: gitFrame.minY, width: 400, height: 160), width: 760)
        expandGitGroup("Changes", until: "git-status.file.README.md", in: app)
        mark("live")
        mark("poster", "poster")
        beat(0.8)
        element("git-status.file.README.md", in: app).click()
        XCTAssertTrue(element("git-status.diff-peek", in: app).waitForExistence(timeout: 10), "no diff peek")
        mark("diff")
        beat(1.2)
        zoomOut("rows")
        mark("end", "end")
    }

    // MARK: - 05 Process Status and Follow by Name

    @MainActor
    func testClip05ProcessStatus() throws {
        let running = BattyUITestHarness.sentinelPath(named: "cargo-running")
        let app = try launchScene("05-process-status", environment: ["DEMO_RUNNING_FILE": running])
        defer { app.terminate() }

        let created = try newSession("tokio-rs/tokio")
        run("clear", pane: created.paneID, app: app)
        chord("j", .command, in: app)
        XCTAssertTrue(element("process-status-view", in: app).waitForExistence(timeout: 15), "the Process Status Pane did not appear")
        run("while true; do touch tokio/src/lib.rs; : > $DEMO_RUNNING_FILE; cargo build --workspace --all-targets; rm -f $DEMO_RUNNING_FILE; sleep 2; done", pane: created.paneID, app: app)
        XCTAssertTrue(waitFor({ FileManager.default.fileExists(atPath: running) }, timeout: 120), "cargo never started")
        beat(1.0)

        mark("start", "start")
        click("process-status.choose-process", in: app)
        let pick = app.menuItems.matching(NSPredicate(format: "title BEGINSWITH 'Pick a Running Process'")).firstMatch
        XCTAssertTrue(pick.waitForExistence(timeout: 5), "no Pick a Running Process item")
        pick.click()
        XCTAssertTrue(element("process-status.running-process-picker", in: app).waitForExistence(timeout: 10), "the process picker did not open")
        mark("picker")
        app.typeText("cargo")
        beat(0.5)
        click("process-status.picker.follow-by-name", in: app)
        mark("follow")
        let row = BattyScreen.elements(withPrefix: "process-status.picker.row.", in: app).first
        XCTAssertNotNil(row, "the picker listed no cargo process")
        row?.click()
        XCTAssertTrue(
            waitFor({ (self.element("process-status.mode", in: app).value as? String) == "following-name" }, timeout: 10),
            "the Pane is not following by name"
        )
        mark("poster", "poster")
        let header = element("process-status.mode", in: app).frame
        zoomIn("pid", around: CGRect(x: header.minX, y: header.minY - 20, width: 360, height: 90), width: 700)
        beat(0.8)

        mark("wait", "speedStart")
        XCTAssertTrue(waitFor({ (self.element("process-status.state-chip", in: app).value as? String) == "waiting" }, timeout: 300), "the build never ended")
        mark("wait", "speedEnd")
        mark("waiting")
        beat(0.6)
        XCTAssertTrue(waitFor({ (self.element("process-status.state-chip", in: app).value as? String) == "running" }, timeout: 60), "the Pane did not pick the restarted process up")
        mark("restart")
        beat(1.4)
        zoomOut("pid")
        mark("end", "end")
    }

    // MARK: - 06 Bell Feed

    @MainActor
    func testClip06BellFeed() throws {
        let app = try launchScene("06-bell-feed")
        defer { app.terminate() }

        let fg = try newSession("brennanMKE/Batty")
        let ok = BattyUITestHarness.sentinelPath(named: "linux-ok")
        let no = BattyUITestHarness.sentinelPath(named: "linux-no")
        run("if test -f ~/.demo-linux-ok; then touch \(ok); else touch \(no); fi; clear", pane: fg.paneID, app: app)
        XCTAssertTrue(waitFor({ FileManager.default.fileExists(atPath: ok) || FileManager.default.fileExists(atPath: no) }, timeout: 20), "the probe did not run")
        let linux = FileManager.default.fileExists(atPath: ok)
        let work = linux ? "make defconfig" : "cargo build --release -p tokio --all-features"
        let slug = linux ? "torvalds/linux" : "tokio-rs/tokio"
        note("long command: \(work)")
        let long = try newSession(slug)
        run("sleep 6; \(work); printf '\\a'; batty notify --title '\(work)' --body Finished", pane: long.paneID, app: app)
        BattyUITestHarness.sessionRow(named: fg.session.name, in: app).click()
        XCTAssertNotNil(BattyCLI.waitForTopology { $0.selectedSessionID == fg.session.id })
        run("git log --oneline -6", pane: fg.paneID, app: app)

        mark("start", "start")
        mark("background")
        mark("wait", "speedStart")
        let sidebarFrame = BattyUITestHarness.sidebar(in: app).frame
        zoomIn("badge", around: CGRect(x: sidebarFrame.minX, y: sidebarFrame.minY + 20, width: 300, height: 100), width: 640)
        let unseenRow = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'session-row.' AND value CONTAINS 'unseen'")).firstMatch
        let badgeShown = waitFor({ unseenRow.exists }, timeout: 120)
        if !badgeShown { note("no row reported an unseen bell within 120 s; continuing to the Bell Feed") }
        mark("wait", "speedEnd")
        mark("bell")
        beat(0.8)
        zoomOut("badge")
        BattyScreen.openBellFeed(in: app)
        mark("feed")
        beat(0.7)
        let entry = BattyScreen.elements(withPrefix: "bell-feed-entry.", in: app).first
        XCTAssertNotNil(entry, "the Bell Feed has no entry")
        entry?.click()
        XCTAssertNotNil(BattyCLI.waitForTopology { $0.selectedSessionID == long.session.id }, "clicking the entry did not jump to the Session")
        mark("jump")
        mark("poster", "poster")
        beat(1.2)
        mark("end", "end")
    }

    // MARK: - 07 Open Quickly and Command Palette

    @MainActor
    func testClip07OpenQuicklyAndPalette() throws {
        let app = try launchScene("07-quick-open", projects: demoProjects(simple: true))
        defer { app.terminate() }

        let first = try newSession("brennanMKE/Batty")
        let second = try newSession("brennanMKE/laya-go")
        run("ls", pane: second.paneID, app: app)
        chord("t", .command, in: app)
        beat(0.5)
        submit("git log --oneline -5", in: app)
        let third = try newSession("brennanMKE/ShortLinks")
        run("ls", pane: third.paneID, app: app)
        BattyUITestHarness.sessionRow(named: first.session.name, in: app).click()
        XCTAssertNotNil(BattyCLI.waitForTopology { $0.selectedSessionID == first.session.id })
        run("clear", pane: first.paneID, app: app)
        beat(0.5)

        mark("start", "start")
        presentOpenQuickly(in: app)
        mark("oq")
        zoomIn("oq", around: element("open-quickly.root", in: app).frame, width: 900)
        beat(0.8)
        app.typeText("lay")
        beat(0.5)
        mark("poster", "poster")
        key(.return, in: app)
        zoomOut("oq")
        XCTAssertTrue(waitFor({ !self.element("open-quickly.root", in: app).exists }, timeout: 10), "Open Quickly did not close")
        XCTAssertNotNil(BattyCLI.waitForTopology { $0.selectedSessionID == second.session.id }, "Open Quickly did not jump to the laya-go Session")
        beat(0.5)

        let beforePanes = terminalPanes(in: app).count
        _ = openCommandPalette(in: app)
        mark("palette")
        app.typeText("Split Horizontally")
        beat(0.4)
        key(.return, in: app)
        XCTAssertTrue(waitFor({ self.terminalPanes(in: app).count > beforePanes }, timeout: 10), "the palette Split did not add a Pane")
        beat(0.3)

        _ = openCommandPalette(in: app)
        app.typeText("Git Status")
        beat(0.4)
        key(.return, in: app)
        XCTAssertTrue(element("git-status.snapshot", in: app).waitForExistence(timeout: 15), "the palette did not open Git Status")
        mark("palettegit")
        beat(1.0)
        mark("end", "end")
    }

    // MARK: - 08 Themes

    @MainActor
    func testClip08Themes() throws {
        let app = try launchScene("08-themes")
        defer { app.terminate() }

        let a = try newSession("brennanMKE/Batty")
        run("git log --oneline --decorate -12", pane: a.paneID, app: app)
        let b = try newSession("brennanMKE/laya-go")
        run("ls -la", pane: b.paneID, app: app)
        let c = try newSession("neovim/neovim")
        run("ls", pane: c.paneID, app: app)
        beat(0.5)

        mark("start", "start")
        chord("t", [.command, .shift], in: app)
        XCTAssertTrue(element("theme-selector.root", in: app).waitForExistence(timeout: 10), "the Theme selector did not open")
        mark("selector")
        for _ in 0..<8 {
            key(.downArrow, in: app)
            beat(0.28)
        }
        key(.return, in: app)
        XCTAssertTrue(waitFor({ !self.element("theme-selector.root", in: app).exists }, timeout: 10), "the selector stayed open")
        for session in [a.session, b.session, c.session] {
            BattyUITestHarness.sessionRow(named: session.name, in: app).click()
            beat(0.35)
        }

        BattyUITestHarness.sessionRow(named: b.session.name, in: app).rightClick()
        let item = app.menuItems.matching(NSPredicate(format: "title BEGINSWITH 'Set Session Theme'")).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), "no Set Session Theme item")
        item.click()
        XCTAssertTrue(element("theme-selector.root", in: app).waitForExistence(timeout: 10), "the Session Theme selector did not open")
        mark("sessiontheme")
        for _ in 0..<7 {
            key(.downArrow, in: app)
            beat(0.28)
        }
        key(.return, in: app)
        XCTAssertTrue(waitFor({ !self.element("theme-selector.root", in: app).exists }, timeout: 10))
        mark("poster", "poster")
        beat(0.4)

        chord("t", [.command, .shift], in: app)
        XCTAssertTrue(element("theme-selector.root", in: app).waitForExistence(timeout: 10))
        mark("globalagain")
        for _ in 0..<4 {
            key(.downArrow, in: app)
            beat(0.28)
        }
        key(.return, in: app)
        beat(0.4)
        for session in [a.session, b.session, c.session] {
            BattyUITestHarness.sessionRow(named: session.name, in: app).click()
            beat(0.4)
        }
        mark("end", "end")
    }

    // MARK: - 09 The batty CLI

    @MainActor
    func testClip09CLI() throws {
        let app = try launchScene("09-cli")
        defer { app.terminate() }

        let created = try newSession("brennanMKE/Batty")
        run("clear", pane: created.paneID, app: app)
        beat(0.5)

        mark("start", "start")
        mark("type")
        mark("typing", "speedStart")
        submit("batty pane split -v --view git-status", in: app)
        mark("typing", "speedEnd")
        XCTAssertTrue(element("git-status.snapshot", in: app).waitForExistence(timeout: 15), "batty pane split --view did not open Git Status")
        mark("view")
        beat(0.6)

        BattyScreen.terminalPane(created.paneID, in: app).click()
        mark("typing2", "speedStart")
        submit("batty notify --title 'Build done' --body 'All green'", in: app)
        mark("typing2", "speedEnd")
        mark("notify")
        mark("poster", "poster")
        beat(1.2)
        mark("end", "end")
    }
}
