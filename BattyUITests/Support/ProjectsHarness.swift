// ProjectsHarness.swift

import Foundation
import XCTest

/// Builds `projects.json` content for the Projects UI tests. The UI-test
/// target does not link BattyKit, so the on-disk shape is written by hand:
/// `docs/ui-features.md` (Projects sections) and `Model/Project.swift` define it.
nonisolated enum ProjectFixture {
    static func tab(_ title: String? = nil, directory: String = ".", command: String? = nil) -> [String: Any] {
        var tab: [String: Any] = ["workingDirectory": directory]
        if let title { tab["title"] = title }
        if let command { tab["startupCommand"] = command }
        return tab
    }

    static func terminal(_ tabs: [[String: Any]] = [ProjectFixture.tab()]) -> [String: Any] {
        ["type": "pane", "pane": ["kind": "terminal", "tabs": tabs]]
    }

    static func view(_ kind: String, repository: String? = nil) -> [String: Any] {
        var pane: [String: Any] = ["kind": kind, "tabs": [[String: Any]]()]
        if let repository { pane["repositoryPath"] = repository }
        return ["type": "pane", "pane": pane]
    }

    static func split(_ direction: String, _ children: [[String: Any]]) -> [String: Any] {
        ["type": "split", "direction": direction, "children": children]
    }

    static func project(
        name: String,
        root: URL,
        layout: [String: Any],
        preset: String? = nil,
        runStartupCommands: Bool = false,
        id: UUID = UUID()
    ) -> [String: Any] {
        var layoutObject: [String: Any] = ["root": layout]
        if let preset { layoutObject["preset"] = preset }
        return [
            "id": id.uuidString,
            "name": name,
            "rootPath": root.path,
            "color": 0,
            "layout": layoutObject,
            "runStartupCommandsOnOpen": runStartupCommands,
        ]
    }

    static func write(_ projects: [[String: Any]], to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: ["version": 1, "projects": projects])
        try data.write(to: file)
    }

    /// The stored Projects, or nil when the file does not exist or cannot be parsed.
    static func read(_ file: URL) -> [[String: Any]]? {
        guard let data = try? Data(contentsOf: file),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object["projects"] as? [[String: Any]]
    }

    static func names(in file: URL) -> [String] {
        (read(file) ?? []).compactMap { $0["name"] as? String }
    }

    /// Every startup command of a stored Project, in Pane and Tab order.
    static func commands(of project: [String: Any]) -> [String] {
        var result: [String] = []
        func walk(_ node: [String: Any]) {
            if let pane = node["pane"] as? [String: Any] {
                for tab in pane["tabs"] as? [[String: Any]] ?? [] {
                    if let command = tab["startupCommand"] as? String { result.append(command) }
                }
            }
            for child in node["children"] as? [[String: Any]] ?? [] { walk(child) }
        }
        if let layout = project["layout"] as? [String: Any], let root = layout["root"] as? [String: Any] { walk(root) }
        return result
    }
}

/// Base class for the Projects UI tests: an isolated `projects.json` per
/// test (the app is pointed at it with `BATTY_UI_TEST_PROJECTS_FILE`, which
/// is honored only beside `BATTY_UI_TEST_SCRIPT`), a scratch directory, and
/// the menu, picker, palette and terminal helpers the classes share.
nonisolated class ProjectsUITestCase: XCTestCase {
    static let projectsFileEnvVar = "BATTY_UI_TEST_PROJECTS_FILE"

    var scratch: URL!
    var storeFile: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        BattyUITestHarness.sweepSentinels()
        scratch = try BattyCLI.makeScratchDirectory()
        storeFile = scratch.appending(path: "store").appending(path: "projects.json")
    }

    override func tearDownWithError() throws {
        BattyUITestHarness.sweepSentinels()
    }

    func makeDirectory(_ name: String, in parent: URL? = nil) throws -> URL {
        let url = (parent ?? scratch).appending(path: name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Launch

    /// Writes `projects` (when given) to the isolated store, launches Batty
    /// with it, and, unless `connectCLI` is false, connects the embedded CLI
    /// so the topology can be read back.
    @MainActor
    func launchApp(
        projects: [[String: Any]]? = nil,
        flagOff: Bool = false,
        script: [[String: Any]] = [],
        connectCLI: Bool = true,
        extraArguments: [String] = []
    ) throws -> (app: XCUIApplication, initial: CLITopology?) {
        if let projects { try ProjectFixture.write(projects, to: storeFile) }
        var environment = [ProjectsUITestCase.projectsFileEnvVar: storeFile.path]
        if flagOff { environment["BATTY_UI_TEST_FORCE_PROJECTS_OFF"] = "1" }
        let app = BattyUITestHarness.launchBatty(script: script, extraEnvironment: environment, extraArguments: extraArguments)
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10), "Batty did not open a window")
        if !script.isEmpty {
            XCTAssertNil(BattyUITestHarness.waitForDriverErrors(timeout: 1), "Driver script failed")
        }
        guard connectCLI else { return (app, nil) }
        let (_, initial) = try BattyCLI.connect(to: app, from: type(of: self))
        return (app, initial)
    }

    // MARK: - Menus

    /// Opens a menu bar menu and returns the menu element.
    @MainActor
    func openMenu(_ title: String, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let barItem = app.menuBars.firstMatch.menuBarItems[title]
        XCTAssertTrue(barItem.waitForExistence(timeout: 5), "no \(title) menu", file: file, line: line)
        barItem.click()
        let menu = barItem.menus.firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 5), "the \(title) menu did not open", file: file, line: line)
        return menu
    }

    /// SwiftUI menu items carry no accessibility identifiers, so they are
    /// found by title. Titles use a real ellipsis, so match the prefix.
    @MainActor
    func menuItem(_ prefix: String, in menu: XCUIElement) -> XCUIElement {
        menu.menuItems.matching(NSPredicate(format: "title BEGINSWITH %@", prefix)).firstMatch
    }

    /// One query, however many items the menu has; reading each item's title is a
    /// round trip per item.
    @MainActor
    func menuItemCount(startingWith prefix: String, in scope: XCUIElement) -> Int {
        scope.menuItems.matching(NSPredicate(format: "title BEGINSWITH %@", prefix)).count
    }

    @MainActor
    func menuTitles(_ menu: XCUIElement) -> [String] {
        menu.menuItems.allElementsBoundByIndex.map(\.title)
    }

    /// Dismisses a menu the caller just opened, one Escape per menu level (2 for a
    /// submenu). The menu bar's items stay in the accessibility tree while their menus
    /// are closed, so "is a menu open" cannot be read back; call it only after opening
    /// one, because with none open Escape would dismiss a sheet instead.
    @MainActor
    func closeMenus(_ app: XCUIApplication, levels: Int = 1) {
        for _ in 0..<levels {
            app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        }
    }

    /// Palette rows are plain `Text`, which XCUITest exposes through `value`, so label,
    /// value and title are all matched. Used by the flag-off absence check and its
    /// flag-on control so the two cannot disagree about what a row is.
    @MainActor
    func paletteRows(containing text: String, in app: XCUIApplication) -> XCUIElementQuery {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@ OR title CONTAINS %@", text, text, text))
    }

    @MainActor
    func isChecked(_ item: XCUIElement) -> Bool {
        if item.isSelected { return true }
        if let number = item.value as? NSNumber { return number.intValue == 1 }
        if let text = item.value as? String { return text == "\u{2713}" || text == "1" || text == "on" }
        return false
    }

    /// File > Open Project > <leaf>; returns after the click.
    @MainActor
    func chooseFromOpenProjectSubmenu(_ leaf: String, in app: XCUIApplication) {
        let file = openMenu("File", in: app)
        let submenuItem = file.menuItems["Open Project"]
        XCTAssertTrue(submenuItem.waitForExistence(timeout: 5), "File has no Open Project submenu")
        submenuItem.click()
        let submenu = submenuItem.menus.firstMatch
        XCTAssertTrue(submenu.waitForExistence(timeout: 5), "Open Project did not open")
        let item = menuItem(leaf, in: submenu)
        XCTAssertTrue(item.waitForExistence(timeout: 5), "Open Project has no \(leaf) item: \(menuTitles(submenu))")
        item.click()
    }

    // MARK: - Picker, palette, editor

    @MainActor
    func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        BattyScreen.element(identifier, in: app)
    }

    @MainActor
    func presentPicker(in app: XCUIApplication) {
        chooseFromOpenProjectSubmenu("Choose Project", in: app)
        XCTAssertTrue(element("project-picker.root", in: app).waitForExistence(timeout: 10), "the Open Project picker did not appear")
    }

    /// The picker's filter text field. Its own `project-picker.filter` identifier is
    /// replaced by the sheet root's `project-picker.root` in the accessibility tree, so
    /// either identifier is accepted and the match is scoped to text fields.
    @MainActor
    func pickerFilterField(in app: XCUIApplication) -> XCUIElement {
        app.textFields.matching(NSPredicate(format: "identifier IN %@", ["project-picker.filter", "project-picker.root"])).firstMatch
    }

    /// Types `filter` until it leaves exactly the card for `name`, so the
    /// best match is the selection when Return is pressed.
    @MainActor
    func filterPicker(to name: String, typing filter: String? = nil, in app: XCUIApplication) {
        let field = pickerFilterField(in: app)
        XCTAssertTrue(field.waitForExistence(timeout: 5), "no picker filter field")
        field.click()
        app.typeText(filter ?? name)
        XCTAssertTrue(element("project-picker.card.\(name)", in: app).waitForExistence(timeout: 5), "no picker card for \(name)")
        XCTAssertTrue(
            waitFor({ BattyScreen.identifiers(withPrefix: "project-picker.card.", in: app).count == 1 }, timeout: 5),
            "the filter did not narrow the picker to \(name): \(BattyScreen.identifiers(withPrefix: "project-picker.card.", in: app))"
        )
    }

    @MainActor
    func pressReturn(in app: XCUIApplication, option: Bool = false) {
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: option ? [.option] : [])
    }

    /// File > Open Project > Choose Project..., filter, Return (Option-Return
    /// for another copy). Waits for the sheet to close.
    @MainActor
    func openThroughPicker(_ name: String, option: Bool = false, in app: XCUIApplication) {
        presentPicker(in: app)
        filterPicker(to: name, in: app)
        pressReturn(in: app, option: option)
        XCTAssertTrue(waitFor({ !self.element("project-picker.root", in: app).exists }, timeout: 10), "the picker did not close after Return")
    }

    @MainActor
    func openCommandPalette(in app: XCUIApplication) -> XCUIElement {
        app.typeKey("p", modifierFlags: [.command, .shift])
        let palette = element("command-palette.root", in: app)
        XCTAssertTrue(palette.waitForExistence(timeout: 5), "the Command Palette did not open")
        return palette
    }

    @MainActor
    func editorWindow(in app: XCUIApplication) -> XCUIElement {
        BattyUITestHarness.window(withIdentifier: "project-editor", in: app)
    }

    @MainActor
    func openEditorFromFileMenu(in app: XCUIApplication) {
        let file = openMenu("File", in: app)
        let item = menuItem("Edit Projects", in: file)
        XCTAssertTrue(item.waitForExistence(timeout: 5), "File has no Edit Projects item: \(menuTitles(file))")
        item.click()
        XCTAssertTrue(editorWindow(in: app).waitForExistence(timeout: 10), "the Project Editor did not open")
    }

    @MainActor
    func replaceText(in identifier: String, with text: String, app: XCUIApplication) {
        let field = element(identifier, in: app)
        XCTAssertTrue(field.waitForExistence(timeout: 5), "no \(identifier)")
        field.click()
        app.typeKey("a", modifierFlags: .command)
        app.typeText(text)
        XCTAssertTrue(
            waitFor({ (field.value as? String) == text }, timeout: 5),
            "\(identifier) holds \(String(describing: field.value)), expected \(text)"
        )
    }

    /// A Pane card in the editor's preview. Every card carries the preview's
    /// `project-editor.preview` identifier instead of `project-editor.pane.<n>`, so a
    /// card is found by its "Pane <n>: <kind>" label.
    @MainActor
    func paneCard(_ number: Int, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(
            format: "(identifier == %@ OR identifier == %@) AND label BEGINSWITH %@",
            "project-editor.preview", "project-editor.pane.\(number)", "Pane \(number):"
        )).firstMatch
    }

    /// Pane 1's card reports the whole preview as its frame, so every card is clicked
    /// near its top-left, which lies inside the card whichever frame it reports.
    @MainActor
    func clickPaneCard(_ number: Int, in app: XCUIApplication) {
        let card = paneCard(number, in: app)
        XCTAssertTrue(card.waitForExistence(timeout: 10), "no Pane \(number) card in the editor")
        card.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.15)).click()
    }

    @MainActor
    func click(_ identifier: String, in app: XCUIApplication) {
        let target = element(identifier, in: app)
        XCTAssertTrue(target.waitForExistence(timeout: 10), "no \(identifier)")
        target.click()
    }

    // MARK: - Sidebar glyph

    /// The Sidebar row's icon is merged into the row's single accessibility element
    /// (`session-row.<title>`), so `session-row.project-glyph` is not addressable. The
    /// icon occupies the left of that element; this returns the fraction of its pixels
    /// that differ from the row background, which tells the solid folder from the
    /// outlined three-column symbol whatever the Session color is.
    @MainActor
    func iconInk(ofRow row: XCUIElement) -> Double? {
        leadingInk(of: row, points: 14, backgroundAtRight: false)
    }

    /// The fraction of the leftmost `points` of `element` whose pixels differ from the
    /// element's background, sampled from its top-left or top-right corner.
    @MainActor
    func leadingInk(of element: XCUIElement, points: Double, backgroundAtRight: Bool) -> Double? {
        let width = element.frame.width
        guard width > 0, let image = element.screenshot().image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let w = image.width, h = image.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let context = CGContext(
            data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let scale = Double(w) / Double(width)
        let regionWidth = min(w, Int(points * scale))
        let backgroundOffset = backgroundAtRight ? (w - 1) * 4 : 0
        let background = (0..<3).map { Int(pixels[backgroundOffset + $0]) }
        var inked = 0
        for y in 0..<h {
            for x in 0..<regionWidth {
                let offset = (y * w + x) * 4
                let difference = (0..<3).map { abs(Int(pixels[offset + $0]) - background[$0]) }.max() ?? 0
                if difference > 48 { inked += 1 }
            }
        }
        return Double(inked) / Double(regionWidth * h)
    }

    /// A menu item's check mark sits in its leading column and XCUITest exposes it
    /// neither as a value nor as selection, so it is read from the item's pixels.
    @MainActor
    func assertCheckMarks(checked: XCUIElement, unchecked: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        guard let on = leadingInk(of: checked, points: 20, backgroundAtRight: true),
              let off = leadingInk(of: unchecked, points: 20, backgroundAtRight: true) else {
            return XCTFail("could not read the menu items", file: file, line: line)
        }
        for (name, item) in [("checked-item", checked), ("unchecked-item", unchecked)] {
            let attachment = XCTAttachment(image: item.screenshot().image)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        XCTAssertGreaterThan(on, off + 0.02, "the open Project's menu item has no check mark (ink \(on) vs \(off))", file: file, line: line)
    }

    /// A Project row's folder glyph is solid; a plain Session's symbol is an outline.
    @MainActor
    func assertProjectGlyph(projectRow: String, plainRow: String, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let project = BattyUITestHarness.sessionRow(named: projectRow, in: app)
        let plain = BattyUITestHarness.sessionRow(named: plainRow, in: app)
        XCTAssertTrue(project.waitForExistence(timeout: 10), "no Sidebar row \(projectRow)", file: file, line: line)
        XCTAssertTrue(plain.exists, "no Sidebar row \(plainRow)", file: file, line: line)
        guard let projectInk = iconInk(ofRow: project), let plainInk = iconInk(ofRow: plain) else {
            return XCTFail("could not read the Sidebar row icons", file: file, line: line)
        }
        for (name, row) in [("project-row-\(projectRow)", project), ("plain-row-\(plainRow)", plain)] {
            let attachment = XCTAttachment(image: row.screenshot().image)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        XCTAssertGreaterThan(projectInk, plainInk + 0.10, "the Project row's icon is not the solid folder glyph (ink \(projectInk) vs \(plainInk))", file: file, line: line)
    }

    // MARK: - Topology and terminals

    func sessions(named name: String, in topology: CLITopology) -> [CLITopology.Session] {
        topology.sessions.filter { $0.name == name }
    }

    /// The Session titled `name` once exactly `count` exist.
    func waitForSessions(named name: String, count: Int = 1) -> [CLITopology.Session] {
        let topology = BattyCLI.waitForTopology { self.sessions(named: name, in: $0).count == count }
        XCTAssertNotNil(topology, "expected \(count) Session(s) titled \(name); have \(BattyCLI.topology()?.sessions.map(\.name) ?? [])")
        return topology.map { sessions(named: name, in: $0) } ?? []
    }

    func closeSession(_ id: UUID) {
        BattyCLI.runExpectingSuccess(["session", "close", "--session", id.uuidString])
        XCTAssertNotNil(BattyCLI.waitForTopology { $0.session(id) == nil }, "Session \(id) never closed")
    }

    /// Clicks the Pane's terminal and runs `command` in it.
    @MainActor
    func runInTerminal(_ command: String, pane: UUID, app: XCUIApplication) {
        let terminal = BattyScreen.terminalPane(pane, in: app)
        XCTAssertTrue(terminal.waitForExistence(timeout: 10), "no terminal for Pane \(pane)")
        terminal.click()
        app.typeText(command)
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
    }

    /// Proves the Pane's shell reads input by having it create a file the
    /// test waits for.
    @MainActor
    func assertShellResponds(pane: UUID, app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let marker = scratch.appending(path: "alive-\(UUID().uuidString.prefix(8))")
        runInTerminal("touch \(BattyCLI.shellQuoted(marker.path))", pane: pane, app: app)
        XCTAssertTrue(BattyUITestHarness.waitForFile(at: marker.path, timeout: 30), "the shell did not run a typed command", file: file, line: line)
    }
}
