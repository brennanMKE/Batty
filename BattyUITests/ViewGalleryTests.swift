// ViewGalleryTests.swift

import XCTest

/// Produces review screenshots of the non-terminal view Panes (#0451); it
/// asserts only that each view rendered. Every shot is a full-screen
/// `XCUIScreen` capture attached as a PNG with `.keepAlways`, so it survives a
/// passing run. `tools/export-ui-screenshots.sh` writes them out by name:
/// `gallery.<view>.<size>.<appearance>`.
///
/// - `large`: window zoomed to the display, Sidebar collapsed, the source
///   terminal Pane hidden so the view Pane has the whole content area.
/// - `narrow`: same window, source Pane shown again and the Split divider
///   dragged so the view Pane is about a quarter of the content width.
/// - `light` / `dark`: the guest's system appearance. The dark side is set by
///   XCUITest clicking "Dark" in System Settings > Appearance (a Pane script
///   only opens the settings URL) and relaunching Batty; no product hook.
///
/// On request only: it skips unless `tools/run-ui-tests-vm.sh` was given a
/// filter naming this class, which exports `BATTY_UI_GALLERY=1` to the
/// runner. It also skips outside the Tart VM, because it drives System
/// Settings and Notification Center.
nonisolated final class ViewGalleryTests: XCTestCase {
    private enum Appearance: String, CaseIterable {
        case light, dark
    }

    /// The guest's current system appearance as far as this class knows. The
    /// golden image is Light. Neither `-AppleInterfaceStyle Dark` nor
    /// `defaults write -g AppleInterfaceStyle` darkens the app, so the setting
    /// is changed through System Settings and the app relaunched (see
    /// `setSystemAppearance`). `tearDownWithError` restores Light so a Dark
    /// guest never reaches another test class.
    nonisolated(unsafe) private static var systemAppearance = Appearance.light

    private var scratch: URL!

    private static var isVirtualMachine: Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("kern.hv_vmm_present", &value, &size, nil, 0) == 0 && value == 1
    }

    override func setUpWithError() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["BATTY_UI_GALLERY"] == "1",
            "ViewGalleryTests runs on request only: tools/run-ui-tests-vm.sh BattyUITests/ViewGalleryTests"
        )
        try XCTSkipUnless(Self.isVirtualMachine, "ViewGalleryTests drives System Settings and Notification Center; run it in the Tart VM only")
        continueAfterFailure = false
        BattyUITestHarness.sweepSentinels()
        scratch = try BattyCLI.makeScratchDirectory()
    }

    override func tearDownWithError() throws {
        defer { BattyUITestHarness.sweepSentinels() }
        if Self.systemAppearance != .light {
            let scratch = try XCTUnwrap(scratch)
            try MainActor.assumeIsolated { try Self.setSystemAppearance(.light, scratch: scratch) }
        }
    }

    // MARK: - Session plumbing

    private struct Gallery {
        let app: XCUIApplication
        let appURL: URL
        let session: CLITopology.Session
        let appearance: Appearance
        var source: UUID { session.focusedPaneID }
    }

    @MainActor
    private func launch(_ appearance: Appearance) throws -> Gallery {
        if Self.systemAppearance != appearance {
            try Self.setSystemAppearance(appearance, scratch: scratch)
        }
        let app = BattyUITestHarness.launchBatty()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10), "Batty did not open a window")
        let (appURL, initial) = try BattyCLI.connect(to: app, from: ViewGalleryTests.self)
        let session = try XCTUnwrap(initial.selectedSession)
        enlargeWindow(app)
        return Gallery(app: app, appURL: appURL, session: session, appearance: appearance)
    }

    @MainActor
    private static func setSystemAppearance(_ appearance: Appearance, scratch: URL) throws {
        let app = BattyUITestHarness.launchBatty()
        defer { app.terminate() }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        let (_, initial) = try BattyCLI.connect(to: app, from: ViewGalleryTests.self)
        let session = try XCTUnwrap(initial.selectedSession)
        let command = try BattyCLI.makeScript(
            in: scratch,
            named: "open-appearance-settings.sh",
            body: "open 'x-apple.systempreferences:com.apple.Appearance-Settings.extension'"
        )
        let scriptPane = try XCTUnwrap(BattyCLI.runExpectingSuccess(["pane", "split", "--pane", session.focusedPaneID.uuidString, "--command", command]).ids.last)
        let settings = XCUIApplication(bundleIdentifier: "com.apple.systempreferences")
        XCTAssertTrue(settings.windows.firstMatch.waitForExistence(timeout: 30), "System Settings did not open")
        let label = appearance == .dark ? "Dark" : "Light"
        let choice = settings.descendants(matching: .any).matching(NSPredicate(format: "label == %@ OR title == %@", label, label)).firstMatch
        if !choice.waitForExistence(timeout: 15) {
            XCTFail("no \(label) control in System Settings > Appearance: \(settings.debugDescription.prefix(3000))")
            return
        }
        choice.click()
        BattyCLI.runExpectingSuccess(["pane", "close", "--pane", scriptPane.uuidString])
        // The menu bar and window chrome flip with the setting; the Dock
        // icon of a regular Settings window is not a signal, so a bounded
        // wait on the screenshot is not possible. The relaunch below reads it.
        BattyUITestHarness.pause(2)
        settings.terminate()
        systemAppearance = appearance
    }

    /// Window > Zoom fills the display; Cmd-B collapses the Sidebar so the
    /// content area is as wide as the window.
    @MainActor
    private func enlargeWindow(_ app: XCUIApplication) {
        let window = app.windows.firstMatch
        let before = window.frame.width
        let menu = app.menuBars.menuBarItems["Window"]
        if menu.exists {
            menu.click()
            let zoom = app.menuBars.menuItems["Zoom"]
            if zoom.waitForExistence(timeout: 3) { zoom.click() }
        }
        let screenWidth = XCUIScreen.main.screenshot().image.size.width
        _ = waitFor({ window.frame.width > before + 20 || window.frame.width >= screenWidth * 0.9 }, timeout: 5)
        app.typeKey("b", modifierFlags: [.command])
        let sidebar = BattyUITestHarness.window(withIdentifier: window.identifier, in: app)
        _ = waitFor({ BattyUITestHarness.isSidebarCollapsed(in: sidebar, expandedWidth: 200) }, timeout: 5)
    }

    @MainActor
    private func openView(_ kind: String, extra: [String] = [], contentIdentifier: String, in gallery: Gallery, source: UUID? = nil) throws -> UUID {
        let target = source ?? gallery.source
        let result = BattyCLI.runExpectingSuccess(["pane", "split", "--view", kind, "--pane", target.uuidString] + extra)
        let id = try XCTUnwrap(result.ids.last, "pane split --view \(kind) printed no id: \(result.summary)")
        XCTAssertTrue(BattyScreen.element(contentIdentifier, in: gallery.app).waitForExistence(timeout: 20), "\(contentIdentifier) never appeared")
        return id
    }

    /// Runs a script in a new terminal Pane split from `source`; the Pane
    /// stays visible until the caller closes or hides it.
    @MainActor
    private func runScript(_ body: String, named name: String, source: UUID) throws -> UUID {
        let command = try BattyCLI.makeScript(in: scratch, named: name, body: body)
        let result = BattyCLI.runExpectingSuccess(["pane", "split", "--pane", source.uuidString, "--command", command])
        return try XCTUnwrap(result.ids.last, "script pane printed no id: \(result.summary)")
    }

    // MARK: - Sizing

    @MainActor
    private func setLarge(_ gallery: Gallery) {
        BattyCLI.runExpectingSuccess(["pane", "hide", "--pane", gallery.source.uuidString])
        let source = BattyScreen.terminalPane(gallery.source, in: gallery.app)
        _ = waitFor({ !source.exists }, timeout: 10)
    }

    /// Shows the source Pane again and drags the Split divider left until the
    /// view Pane (on the right) is about a quarter of the window.
    @MainActor
    private func setNarrow(_ gallery: Gallery, view: UUID, contentIdentifier: String) throws {
        let app = gallery.app
        BattyCLI.runExpectingSuccess(["pane", "show", gallery.source.uuidString])
        let source = BattyScreen.terminalPane(gallery.source, in: app)
        XCTAssertTrue(source.waitForExistence(timeout: 10))
        let window = app.windows.firstMatch
        let origin = window.coordinate(withNormalizedOffset: .zero)
        func point(_ x: CGFloat, _ y: CGFloat) -> XCUICoordinate {
            origin.withOffset(CGVector(dx: x - window.frame.minX, dy: y - window.frame.minY))
        }
        let startWidth = source.frame.width
        let targetX = window.frame.minX + window.frame.width * 0.76
        let y = source.frame.midY
        for offset in stride(from: CGFloat(1), through: 12, by: 2) {
            let x = source.frame.maxX + offset
            point(x, y).press(forDuration: 0.1, thenDragTo: point(targetX, y))
            if waitFor({ source.frame.width > startWidth + 40 }, timeout: 2) { break }
        }
        XCTAssertGreaterThan(source.frame.width, startWidth + 40, "the Split divider did not move; the view Pane is not narrow")
        XCTAssertTrue(BattyScreen.element(contentIdentifier, in: app).waitForExistence(timeout: 5))
    }

    // MARK: - Capture

    /// Dismisses notification banners over the app: first the "App Background
    /// Activity" one raised by #0419's LaunchAgent bootstrap, then Batty's own
    /// "Notifications may include alerts" one. Both are persistent banners, not
    /// transient ones, so waiting does not clear them; hovering reveals a Close
    /// button, with a swipe as the fallback.
    @MainActor
    @discardableResult
    private func dismissBanners() -> Bool {
        var dismissed = false
        let center = XCUIApplication(bundleIdentifier: "com.apple.notificationcenterui")
        let predicate = NSPredicate(format: "label CONTAINS 'can run in the background' OR label CONTAINS 'Notifications may include' OR title CONTAINS 'App Background Activity'")
        for _ in 0..<4 {
            let banner = center.descendants(matching: .any).matching(predicate).firstMatch
            guard banner.exists else { break }
            dismissed = true
            banner.hover()
            let close = center.groups["AXNotificationListItems"].buttons["Close"].firstMatch
            if close.waitForExistence(timeout: 2) { close.click() } else { banner.swipeRight() }
            _ = waitFor({ !banner.exists }, timeout: 5)
        }
        if dismissed { pause(1.5) }
        return dismissed
    }

    @MainActor
    private func attachText(_ text: String, name: String) {
        let attachment = XCTAttachment(string: text)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Opens every collapsed disclosure. The SwiftUI triangle's element frame
    /// spans the whole label, and `click()` on its centre hits the label text,
    /// which does not toggle on macOS; the arrow sits near the frame's leading
    /// edge, so the click goes there. Re-queries after each click because rows
    /// move; an already-open group (value 1) is left alone.
    @MainActor
    private func expandDisclosures(in app: XCUIApplication) {
        for _ in 0..<12 {
            let collapsed = app.disclosureTriangles.allElementsBoundByIndex.first { ($0.value as? NSNumber)?.intValue == 0 && $0.isHittable }
            guard let triangle = collapsed else { return }
            let before = triangle.frame
            triangle.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 25, dy: before.height / 2)).click()
            if !waitFor({ (triangle.value as? NSNumber)?.intValue == 1 }, timeout: 2) {
                triangle.click()
                _ = waitFor({ (triangle.value as? NSNumber)?.intValue == 1 }, timeout: 2)
            }
        }
    }

    @MainActor
    private func capture(_ name: String, _ gallery: Gallery, note: String? = nil) {
        dismissBanners()
        gallery.app.activate()
        for _ in 0..<5 {
            if !dismissBanners() { break }
        }
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(uniformTypeIdentifier: "public.png", name: "gallery.\(name).\(gallery.appearance.rawValue)", payload: shot.pngRepresentation)
        attachment.lifetime = .keepAlways
        add(attachment)
        if let note { print("gallery note \(name): \(note)") }
    }

    @MainActor
    private func captureBothSizes(_ name: String, _ gallery: Gallery, view: UUID, contentIdentifier: String, prepare: (String) -> Void = { _ in }) throws {
        setLarge(gallery)
        prepare("\(name).large")
        capture("\(name).large", gallery)
        try setNarrow(gallery, view: view, contentIdentifier: contentIdentifier)
        prepare("\(name).narrow")
        capture("\(name).narrow", gallery)
    }

    // MARK: - Views

    @MainActor
    func testGitStatusPopulatedRepository() throws {
        for appearance in Appearance.allCases {
            let gallery = try launch(appearance)
            defer { gallery.app.terminate() }

            let repo = scratch.appending(path: "gallery-repo").path
            let done = BattyUITestHarness.sentinelPath(named: "gallery-git-done")
            let script = Self.gitFixtureScript(repo: repo, done: done)
            let scriptPane = try runScript(script, named: "git-fixture.sh", source: gallery.source)
            XCTAssertTrue(BattyUITestHarness.waitForFile(at: done, timeout: 90), "the git fixture script never finished (needs git in the guest)")
            BattyCLI.runExpectingSuccess(["pane", "close", "--pane", scriptPane.uuidString])

            let view = try openView("git-status", extra: ["--path", repo], contentIdentifier: "git-status.snapshot", in: gallery)
            XCTAssertFalse(BattyScreen.element("git-status.not-a-repo", in: gallery.app).exists)
            try captureBothSizes("git-status", gallery, view: view, contentIdentifier: "git-status.snapshot") { _ in
                expandDisclosures(in: gallery.app)
                XCTAssertTrue(BattyScreen.element("git-status.file.scratch.txt", in: gallery.app).waitForExistence(timeout: 10), "the populated repository's rows are not on screen")
            }
        }
    }

    /// A repository in the middle of a merge conflict: the operation banner
    /// and the Conflicted group.
    @MainActor
    func testGitStatusMergeConflict() throws {
        for appearance in Appearance.allCases {
            let gallery = try launch(appearance)
            defer { gallery.app.terminate() }

            let repo = scratch.appending(path: "gallery-conflict").path
            let done = BattyUITestHarness.sentinelPath(named: "gallery-conflict-done")
            let scriptPane = try runScript(Self.conflictFixtureScript(repo: repo, done: done), named: "conflict-fixture.sh", source: gallery.source)
            XCTAssertTrue(BattyUITestHarness.waitForFile(at: done, timeout: 90), "the conflict fixture script never finished")
            BattyCLI.runExpectingSuccess(["pane", "close", "--pane", scriptPane.uuidString])

            XCTAssertFalse(FileManager.default.fileExists(atPath: done + ".merged-cleanly"), "the merge succeeded; the fixture has no conflict")
            let view = try openView("git-status", extra: ["--path", repo], contentIdentifier: "git-status.snapshot", in: gallery)
            // The banner's own identifier is not exposed on its own element;
            // its text is the signal.
            let banner = gallery.app.descendants(matching: .any).matching(NSPredicate(format: "identifier == 'git-status.operation-banner' OR label CONTAINS 'Merge in progress' OR value CONTAINS 'Merge in progress'")).firstMatch
            XCTAssertTrue(banner.waitForExistence(timeout: 10), "no merge operation banner")
            try captureBothSizes("git-status.merge-conflict", gallery, view: view, contentIdentifier: "git-status.snapshot") { _ in
                expandDisclosures(in: gallery.app)
            }
        }
    }

    /// A linked worktree on a long branch with an upstream, 2 ahead and
    /// 1 behind, plus a stash: every header badge at once.
    @MainActor
    func testGitStatusWorktreeWithStash() throws {
        for appearance in Appearance.allCases {
            let gallery = try launch(appearance)
            defer { gallery.app.terminate() }

            let worktree = scratch.appending(path: "gallery-worktree").path
            let done = BattyUITestHarness.sentinelPath(named: "gallery-worktree-done")
            let scriptPane = try runScript(Self.worktreeFixtureScript(root: scratch.path, worktree: worktree, done: done), named: "worktree-fixture.sh", source: gallery.source)
            XCTAssertTrue(BattyUITestHarness.waitForFile(at: done, timeout: 90), "the worktree fixture script never finished")
            BattyCLI.runExpectingSuccess(["pane", "close", "--pane", scriptPane.uuidString])

            let view = try openView("git-status", extra: ["--path", worktree], contentIdentifier: "git-status.snapshot", in: gallery)
            XCTAssertFalse(BattyScreen.element("git-status.not-a-repo", in: gallery.app).exists)
            for text in ["Worktree", "1 stash"] {
                let badge = gallery.app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text)).firstMatch
                XCTAssertTrue(badge.waitForExistence(timeout: 10), "no '\(text)' badge in the header")
            }
            let behind = gallery.app.descendants(matching: .any).matching(NSPredicate(format: "label == '1' OR value == '1'")).firstMatch
            XCTAssertTrue(behind.waitForExistence(timeout: 10), "no behind count in the header")
            try captureBothSizes("git-status.worktree", gallery, view: view, contentIdentifier: "git-status.snapshot")
        }
    }

    @MainActor
    func testGitStatusNotARepository() throws {
        for appearance in Appearance.allCases {
            let gallery = try launch(appearance)
            defer { gallery.app.terminate() }

            let plain = scratch.appending(path: "plain-directory")
            try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
            let view = try openView("git-status", extra: ["--path", plain.path], contentIdentifier: "git-status.not-a-repo", in: gallery)
            try captureBothSizes("git-status.not-a-repo", gallery, view: view, contentIdentifier: "git-status.not-a-repo")
        }
    }

    /// Process Status with no `--pid`: it follows the source terminal Pane's
    /// foreground process (an idle shell).
    @MainActor
    func testProcessStatusFollowingTheTerminal() throws {
        for appearance in Appearance.allCases {
            let gallery = try launch(appearance)
            defer { gallery.app.terminate() }

            let view = try openView("process-status", contentIdentifier: "process-status-view", in: gallery)
            // Per-pid CPU needs a baseline from an earlier tick (1 s interval).
            pause(4)
            try captureBothSizes("process-status.following", gallery, view: view, contentIdentifier: "process-status-view") { _ in
                expandDisclosures(in: gallery.app)
                pause(1.5)
            }
        }
    }

    /// Process Status pinned with `--pid` to a busy child started by a
    /// `--command` script.
    @MainActor
    func testProcessStatusPinnedToBusyChild() throws {
        for appearance in Appearance.allCases {
            let gallery = try launch(appearance)
            defer { gallery.app.terminate() }

            let pidFile = BattyUITestHarness.sentinelPath(named: "gallery-busy-pid")
            let body = """
            (while :; do :; done) &
            busy=$!
            sleep 30 &
            echo $busy > \(BattyCLI.shellQuoted(pidFile + ".tmp"))
            mv \(BattyCLI.shellQuoted(pidFile + ".tmp")) \(BattyCLI.shellQuoted(pidFile))
            wait
            """
            let scriptPane = try runScript(body, named: "busy.sh", source: gallery.source)
            XCTAssertTrue(BattyUITestHarness.waitForFile(at: pidFile, timeout: 30), "the busy script never wrote its pid")
            let pid = try XCTUnwrap(Int(BattyCLI.readTrimmed(pidFile) ?? ""), "unreadable pid")
            BattyCLI.runExpectingSuccess(["pane", "hide", "--pane", scriptPane.uuidString])

            let view = try openView("process-status", extra: ["--pid", String(pid)], contentIdentifier: "process-status-view", in: gallery)
            pause(4)
            try captureBothSizes("process-status.pid", gallery, view: view, contentIdentifier: "process-status-view") { _ in
                expandDisclosures(in: gallery.app)
                pause(1.5)
            }
        }
    }

    @MainActor
    func testSystemMetrics() throws {
        for appearance in Appearance.allCases {
            let gallery = try launch(appearance)
            defer { gallery.app.terminate() }

            let view = try openView("system-metrics", contentIdentifier: "system-metrics-pane", in: gallery)
            if BattyScreen.element("system-metrics-waiting", in: gallery.app).exists {
                capture("system-metrics.waiting", gallery)
            }
            XCTAssertTrue(BattyScreen.element("system-metrics-refresh-button", in: gallery.app).waitForExistence(timeout: 20), "system metrics never produced a first sample")
            // Per-core utilization is a delta between ticks (1 s interval).
            pause(4)
            try captureBothSizes("system-metrics", gallery, view: view, contentIdentifier: "system-metrics-pane") { _ in pause(1.5) }
        }
    }

    @MainActor
    func testLMStudioDashboardDisconnected() throws {
        for appearance in Appearance.allCases {
            let gallery = try launch(appearance)
            defer { gallery.app.terminate() }

            let view = try openView("lm-studio-dashboard", contentIdentifier: "lmstudio-dashboard", in: gallery)
            let checking = BattyScreen.element("lmstudio-connection-pill.checking", in: gallery.app)
            _ = waitFor({ !checking.exists }, timeout: 20)
            let pill = gallery.app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'lmstudio-connection-pill.'")).firstMatch
            XCTAssertTrue(pill.waitForExistence(timeout: 10))
            XCTAssertNotEqual(pill.identifier, "lmstudio-connection-pill.connected")
            try captureBothSizes("lm-studio-dashboard", gallery, view: view, contentIdentifier: "lmstudio-dashboard")
        }
    }

    // MARK: - Fixtures

    /// Builds a repository with real `git` inside a Pane (the sandboxed
    /// runner cannot exec git): a bare origin, several commits, a second
    /// clone that pushes so the branch is behind, local commits so it is
    /// ahead, then staged, modified, deleted, renamed and untracked files and
    /// a long path.
    private static func gitFixtureScript(repo: String, done: String) -> String {
        let q = BattyCLI.shellQuoted
        return """
        set -e
        export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
        export GIT_AUTHOR_NAME='Ada Lovelace' GIT_AUTHOR_EMAIL=ada@example.com
        export GIT_COMMITTER_NAME='Ada Lovelace' GIT_COMMITTER_EMAIL=ada@example.com
        root=$(dirname \(q(repo)))
        rm -rf \(q(repo)) "$root/origin.git" "$root/other"
        git init -q --bare -b main "$root/origin.git"
        git init -q -b main \(q(repo))
        cd \(q(repo))
        deep=Sources/Core/Networking/Transport/Implementations/Experimental/VeryLongDescriptiveFileNameForTheExperimentalTransportLayer.swift
        mkdir -p Sources/App Sources/Core docs "$(dirname "$deep")"
        printf 'original\\n' > "$deep"
        printf 'import Foundation\\n\\nfunc main() {\\n    print("hello")\\n}\\n' > Sources/App/main.swift
        printf 'struct Engine {\\n    var speed = 1\\n}\\n' > Sources/Core/Engine.swift
        printf 'struct Legacy {}\\n' > Sources/Core/Legacy.swift
        printf '# Project\\n\\nA sample repository.\\n' > README.md
        printf 'old notes\\n' > docs/notes.txt
        printf 'one\\ntwo\\nthree\\n' > docs/todo.txt
        git add -A
        git commit -q -m 'Initial import'
        printf 'struct Engine {\\n    var speed = 2\\n    var gears = 6\\n}\\n' > Sources/Core/Engine.swift
        git commit -q -am 'Add gears to Engine'
        git remote add origin "$root/origin.git"
        git push -q -u origin main
        git clone -q "$root/origin.git" "$root/other"
        (cd "$root/other" && printf 'Changelog\\n' > CHANGELOG.md && git add CHANGELOG.md && git commit -q -m 'Add changelog' && git push -q origin main)
        git fetch -q
        printf 'struct Engine {\\n    var speed = 3\\n    var gears = 6\\n    var turbo = true\\n}\\n' > Sources/Core/Engine.swift
        git commit -q -am 'Enable turbo'
        printf '# Project\\n\\nA sample repository with more words.\\n' > README.md
        git commit -q -am 'Expand the README'
        printf 'func main() {\\n    print("hello, world")\\n}\\n' > Sources/App/main.swift
        git add Sources/App/main.swift
        printf 'let added = true\\n' > Sources/App/Added.swift
        git add Sources/App/Added.swift
        git mv Sources/Core/Legacy.swift Sources/Core/Modern.swift
        printf 'one\\ntwo\\nthree\\nfour\\nfive\\n' > docs/todo.txt
        rm docs/notes.txt
        printf 'changed\\n' > "$deep"
        printf 'also untracked\\n' > notes-to-self.md
        printf 'scratch\\n' > scratch.txt
        printf 'staged and then modified again\\n' > staged-then-modified.txt
        git add staged-then-modified.txt
        printf 'staged and then modified again, twice\\n' > staged-then-modified.txt
        touch \(q(done))
        exec sleep 3600
        """
    }

    /// A merge stopped on a conflict.
    private static func conflictFixtureScript(repo: String, done: String) -> String {
        let q = BattyCLI.shellQuoted
        return """
        set -e
        export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
        export GIT_AUTHOR_NAME='Ada Lovelace' GIT_AUTHOR_EMAIL=ada@example.com
        export GIT_COMMITTER_NAME='Ada Lovelace' GIT_COMMITTER_EMAIL=ada@example.com
        rm -rf \(q(repo))
        git init -q -b main \(q(repo))
        cd \(q(repo))
        printf 'line one\\nline two\\nline three\\n' > config.txt
        printf 'a\\nb\\n' > other.txt
        git add -A
        git commit -q -m 'Base'
        git checkout -q -b feature
        printf 'line one\\nfeature two\\nline three\\n' > config.txt
        printf 'a\\nfeature b\\n' > other.txt
        git commit -q -am 'Feature edits'
        git checkout -q main
        printf 'line one\\nmain two\\nline three\\n' > config.txt
        printf 'a\\nmain b\\n' > other.txt
        git commit -q -am 'Main edits'
        if git merge feature > /dev/null 2>&1; then touch \(q(done + ".merged-cleanly")); fi
        touch \(q(done))
        exec sleep 3600
        """
    }

    private static func worktreeFixtureScript(root: String, worktree: String, done: String) -> String {
        let q = BattyCLI.shellQuoted
        let main = root + "/gallery-worktree-main"
        let origin = root + "/gallery-worktree-origin.git"
        return """
        set -e
        export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
        export GIT_AUTHOR_NAME='Ada Lovelace' GIT_AUTHOR_EMAIL=ada@example.com
        export GIT_COMMITTER_NAME='Ada Lovelace' GIT_COMMITTER_EMAIL=ada@example.com
        rm -rf \(q(main)) \(q(origin)) \(q(worktree))
        git init -q --bare -b main \(q(origin))
        git init -q -b main \(q(main))
        cd \(q(main))
        printf 'one\\n' > a.txt
        git add -A
        git commit -q -m 'Base'
        git remote add origin \(q(origin))
        git push -q -u origin main
        printf 'two\\n' > a.txt
        git stash -q
        git worktree add -q -b feature/a-very-long-branch-name-for-narrow-panes \(q(worktree)) main
        git commit -q --allow-empty -m 'Upstream moves on'
        git push -q origin main
        cd \(q(worktree))
        git branch -q --set-upstream-to=origin/main
        printf 'x\\n' > b.txt
        git add -A
        git commit -q -m 'Ahead one'
        printf 'y\\n' > c.txt
        git add -A
        git commit -q -m 'Ahead two'
        printf 'dirty\\n' > d.txt
        touch \(q(done))
        exec sleep 3600
        """
    }
}
