// BackgroundImagesWindowTests.swift

import XCTest

/// The Background Images window and picker (#0552). The library sits beside the
/// isolated `projects.json`. Assertions go by named cell, never by total count,
/// because the app-wide folder scanned here is the guest's real one.
nonisolated final class BackgroundImagesWindowTests: ProjectsUITestCase {
    private var libraryFolder: URL { storeFile.deletingLastPathComponent().appending(path: "BackgroundImages") }
    private var projectFolder: URL { storeFile.deletingLastPathComponent().appending(path: "ProjectBackgrounds") }

    private func project(name: String, imagePath: String) throws -> [String: Any] {
        var project = ProjectFixture.project(
            name: name,
            root: try makeDirectory("root-\(name)"),
            layout: ProjectFixture.terminal(),
            preset: "singlePane"
        )
        project["background"] = [
            "imagePath": imagePath, "fit": "contain", "position": "top-right",
            "imageOpacity": 0.35, "terminalOpacity": 0.6,
        ] as [String: Any]
        return project
    }

    @MainActor
    private func window(in app: XCUIApplication) -> XCUIElement {
        BattyUITestHarness.window(withIdentifier: "background-images", in: app)
    }

    @MainActor
    private func openFromFileMenu(in app: XCUIApplication) {
        let menu = openMenu("File", in: app)
        menuItem("Background Images", in: menu).click()
        XCTAssertTrue(window(in: app).waitForExistence(timeout: 5), "File menu did not open the window")
    }

    @MainActor
    private func cell(_ name: String, in app: XCUIApplication) -> XCUIElement {
        element("background-images.cell.\(name)", in: app)
    }

    /// Share of the cell's pixels showing the fixture's own colour, read in sRGB. A
    /// placeholder or a "Can't be used" cell is grey and white, so this is near zero
    /// until that image's thumbnail has been drawn.
    @MainActor
    private func pictureCoverage(of cell: XCUIElement, name: String) -> Double {
        guard let image = cell.screenshot().image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let space = CGColorSpace(name: CGColorSpace.sRGB)
        else { return 0 }
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return 0 }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let color = BackgroundImageFixture.color(named: name)
        let expected = [color.red, color.green, color.blue].map { Int($0 * 255) }
        var matching = 0
        for offset in stride(from: 0, to: pixels.count, by: 4)
        where (0..<3).allSatisfy({ abs(Int(pixels[offset + $0]) - expected[$0]) <= 25 }) {
            matching += 1
        }
        return Double(matching) / Double(width * height)
    }

    /// Goes by pixels because XCUITest sees no value on the cell, a `.contain` container
    /// that it reads as a bare Group. The thumbnail fills over half the cell, so a quarter
    /// can't be met by a stray outline or highlight.
    @MainActor
    private func waitForPicture(_ name: String, in app: XCUIApplication) {
        let cell = cell(name, in: app)
        XCTAssertTrue(cell.waitForExistence(timeout: 10), "no cell for \(name)")
        var coverage = 0.0
        let drawn = waitFor({
            coverage = self.pictureCoverage(of: cell, name: name)
            return coverage > 0.25
        }, timeout: 10)
        XCTAssertTrue(drawn, "\(name) never showed a picture: \(coverage) of the cell has its colour")
    }

    @MainActor
    private func openSettingsAppearance(in app: XCUIApplication) {
        app.typeKey(",", modifierFlags: [.command])
        let appearance = app.toolbars.buttons["Appearance"]
        XCTAssertTrue(appearance.waitForExistence(timeout: 10))
        appearance.click()
    }

    @MainActor
    private func openPaneSheet(in app: XCUIApplication) {
        let disclosure = app.descendants(matching: .disclosureTriangle).firstMatch
        XCTAssertTrue(disclosure.waitForExistence(timeout: 5))
        disclosure.click()
        let gear = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'pane-background-settings.'")).firstMatch
        XCTAssertTrue(gear.waitForExistence(timeout: 5))
        gear.click()
        let custom = app.buttons["pane-background-sheet.custom"]
        XCTAssertTrue(custom.waitForExistence(timeout: 5))
        custom.click()
    }

    @MainActor
    private func expectPicker(in app: XCUIApplication) {
        XCTAssertTrue(element("background-images.picker.root", in: app).waitForExistence(timeout: 5), "Choose did not open the picker")
    }

    // MARK: - Entry points

    @MainActor
    func testFileMenuOpensTheWindowAndWindowMenuListsIt() throws {
        let (app, _) = try launchApp(projects: [], connectCLI: false)
        defer { app.terminate() }
        openFromFileMenu(in: app)
        let windowMenu = openMenu("Window", in: app)
        XCTAssertTrue(menuTitles(windowMenu).contains("Background Images"), "not in the Window menu: \(menuTitles(windowMenu))")
        closeMenus(app)
    }

    @MainActor
    func testCommandPaletteOpensTheWindow() throws {
        let (app, _) = try launchApp(projects: [], connectCLI: false)
        defer { app.terminate() }
        _ = openCommandPalette(in: app)
        app.typeText("Background Images")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(window(in: app).waitForExistence(timeout: 5), "the palette did not open the window")
    }

    @MainActor
    func testSettingsManageImagesOpensTheWindow() throws {
        let (app, _) = try launchApp(projects: [], connectCLI: false)
        defer { app.terminate() }
        openSettingsAppearance(in: app)
        let manage = app.buttons["appearance-background.manage-images"]
        XCTAssertTrue(manage.waitForExistence(timeout: 5))
        manage.click()
        XCTAssertTrue(window(in: app).waitForExistence(timeout: 5), "Manage Images did not open the window")
    }

    // MARK: - The window

    @MainActor
    func testAnImageShowsItsThumbnailNameAndSize() throws {
        _ = try BackgroundImageFixture.write(named: "Harbor-show", in: libraryFolder)
        let (app, _) = try launchApp(projects: [], connectCLI: false)
        defer { app.terminate() }
        openFromFileMenu(in: app)
        waitForPicture("Harbor-show", in: app)
        XCTAssertTrue(element("background-images.cell.Harbor-show.size", in: app).exists)
        XCTAssertEqual(element("background-images.cell.Harbor-show.uses", in: app).value as? String, "Not in use")
    }

    @MainActor
    func testRemovingAnUnusedImageRemovesItsCell() throws {
        let path = try BackgroundImageFixture.write(named: "Harbor-remove", in: libraryFolder)
        let (app, _) = try launchApp(projects: [], connectCLI: false)
        defer { app.terminate() }
        openFromFileMenu(in: app)
        waitForPicture("Harbor-remove", in: app)
        cell("Harbor-remove", in: app).click()
        app.buttons["background-images.remove"].click()
        let confirm = app.buttons["background-images.confirm-remove"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.click()
        XCTAssertTrue(waitFor({ !self.cell("Harbor-remove", in: app).exists }, timeout: 10), "the cell stayed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    @MainActor
    func testRemovingAProjectsImageListsTheProjectAndClearsItsPath() throws {
        let path = try BackgroundImageFixture.write(named: "Harbor-project", in: projectFolder)
        let (app, _) = try launchApp(projects: [try project(name: "Uses Image", imagePath: path)], connectCLI: false)
        defer { app.terminate() }
        openFromFileMenu(in: app)
        waitForPicture("Harbor-project", in: app)
        XCTAssertEqual(element("background-images.cell.Harbor-project.uses", in: app).value as? String, "Project Uses Image")
        cell("Harbor-project", in: app).click()
        app.buttons["background-images.remove"].click()
        let confirm = app.buttons["background-images.confirm-remove"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.click()
        XCTAssertTrue(waitFor({
            let background = ProjectFixture.read(self.storeFile)?.first?["background"] as? [String: Any]
            return background != nil && background?["imagePath"] == nil
        }, timeout: 10), "the Project kept its path")
        let background = ProjectFixture.read(storeFile)?.first?["background"] as? [String: Any]
        XCTAssertEqual(background?["terminalOpacity"] as? Double, 0.6)
    }

    /// A fresh launch, so this is the first open: the grid only exists once the
    /// scan has finished, and no click has given it focus.
    @MainActor
    func testArrowKeySelectsACellOnTheFirstOpen() throws {
        _ = try BackgroundImageFixture.write(named: "Harbor-keys", in: libraryFolder)
        let (app, _) = try launchApp(projects: [], connectCLI: false)
        defer { app.terminate() }
        openFromFileMenu(in: app)
        waitForPicture("Harbor-keys", in: app)
        let remove = app.buttons["background-images.remove"]
        XCTAssertFalse(remove.isEnabled)
        app.typeKey(.rightArrow, modifierFlags: [])
        XCTAssertTrue(waitFor({ remove.isEnabled }, timeout: 5), "the arrow key selected nothing")
    }

    // MARK: - Selecting keeps the grid still

    private static let jumpNames = (0..<24).map { String(format: "Jump-%02d", $0) }

    /// 24 images make six rows at the window's 4 columns, so the grid scrolls.
    private func seedScrollingLibrary() throws {
        for name in Self.jumpNames {
            _ = try BackgroundImageFixture.write(named: name, in: libraryFolder)
        }
    }

    /// The frame once two reads in a row agree, so a scroll or a jump has settled.
    /// The timeout only bounds a regression.
    @MainActor
    private func settledFrame(of element: XCUIElement) -> CGRect {
        var last = element.frame
        _ = waitFor({
            let now = element.frame
            defer { last = now }
            return now == last
        }, timeout: 3)
        return element.frame
    }

    /// Kept on a pass too, so a run that doesn't reproduce still shows what it measured.
    @MainActor
    private func record(_ label: String, _ before: CGRect, _ after: CGRect) {
        let attachment = XCTAttachment(string: "\(label): before \(before) after \(after)")
        attachment.name = "jump-measure \(label)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func scrollGridDown(in app: XCUIApplication) {
        let root = element("background-images.root", in: app)
        XCTAssertTrue(root.waitForExistence(timeout: 5))
        root.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)).hover()
        for _ in 0..<2 { root.scroll(byDeltaX: 0, deltaY: -240) }
        _ = settledFrame(of: cell(Self.jumpNames[12], in: app))
    }

    /// Cells wholly inside the window, below its tab and above its bottom bar.
    @MainActor
    private func visibleJumpCells(in app: XCUIApplication) -> [XCUIElement] {
        let bounds = window(in: app).frame.insetBy(dx: 0, dy: 70)
        return Self.jumpNames.map { cell($0, in: app) }.filter { cell in
            cell.exists && cell.isHittable && bounds.contains(cell.frame)
        }
    }

    @MainActor
    func testClickingACellAfterScrollingKeepsTheGridStill() throws {
        try seedScrollingLibrary()
        let (app, _) = try launchApp(projects: [], connectCLI: false)
        defer { app.terminate() }
        app.activate()
        XCTAssertEqual(app.state, .runningForeground, "Batty is not frontmost")
        openFromFileMenu(in: app)
        XCTAssertTrue(cell(Self.jumpNames[0], in: app).waitForExistence(timeout: 10), "the grid never showed")
        scrollGridDown(in: app)
        let visible = visibleJumpCells(in: app)
        XCTAssertGreaterThanOrEqual(visible.count, 2, "fewer than two whole cells on screen after scrolling")
        guard visible.count >= 2 else { return }
        let a = visible[0], b = visible[visible.count - 1]

        let bBefore = settledFrame(of: b)
        a.click()
        XCTAssertTrue(waitFor({ app.buttons["background-images.remove"].isEnabled }, timeout: 5), "the click selected nothing")
        let bAfter = settledFrame(of: b)
        record("first click", bBefore, bAfter)
        XCTAssertEqual(bAfter.minY, bBefore.minY, accuracy: 1, "the grid moved on the first click")

        let aBefore = settledFrame(of: a)
        b.click()
        let aAfter = settledFrame(of: a)
        record("later click", aBefore, aAfter)
        XCTAssertEqual(aAfter.minY, aBefore.minY, accuracy: 1, "the grid moved on a later click")
    }

    @MainActor
    func testArrowKeySelectionAfterScrollingKeepsTheGridStill() throws {
        try seedScrollingLibrary()
        let (app, _) = try launchApp(projects: [], connectCLI: false)
        defer { app.terminate() }
        app.activate()
        XCTAssertEqual(app.state, .runningForeground, "Batty is not frontmost")
        openFromFileMenu(in: app)
        XCTAssertTrue(cell(Self.jumpNames[0], in: app).waitForExistence(timeout: 10), "the grid never showed")
        scrollGridDown(in: app)
        let visible = visibleJumpCells(in: app)
        XCTAssertGreaterThanOrEqual(visible.count, 3, "fewer than three whole cells on screen after scrolling")
        guard visible.count >= 3 else { return }
        visible[0].click()
        XCTAssertTrue(waitFor({ app.buttons["background-images.remove"].isEnabled }, timeout: 5), "the click selected nothing")
        let probe = visible[visible.count - 1]
        let before = settledFrame(of: probe)
        app.typeKey(.rightArrow, modifierFlags: [])
        let after = settledFrame(of: probe)
        record("arrow key", before, after)
        XCTAssertEqual(after.minY, before.minY, accuracy: 1, "the grid moved on an arrow key")
    }

    /// A cell the bottom edge cuts off: selecting it is a highlight, not a scroll.
    @MainActor
    func testClickingACellCutOffAtTheBottomKeepsTheGridStill() throws {
        try seedScrollingLibrary()
        let (app, _) = try launchApp(projects: [], connectCLI: false)
        defer { app.terminate() }
        app.activate()
        XCTAssertEqual(app.state, .runningForeground, "Batty is not frontmost")
        openFromFileMenu(in: app)
        XCTAssertTrue(cell(Self.jumpNames[0], in: app).waitForExistence(timeout: 10), "the grid never showed")
        let windowFrame = window(in: app).frame
        let cutOff = Self.jumpNames.map { cell($0, in: app) }.first { cell in
            cell.exists && cell.isHittable && cell.frame.maxY > windowFrame.maxY - 60
        }
        let probe = visibleJumpCells(in: app).first
        XCTAssertNotNil(cutOff, "no cell is cut off at the bottom")
        XCTAssertNotNil(probe, "no whole cell on screen")
        guard let cutOff, let probe else { return }
        let before = settledFrame(of: probe)
        cutOff.click()
        XCTAssertTrue(waitFor({ app.buttons["background-images.remove"].isEnabled }, timeout: 5), "the click selected nothing")
        let after = settledFrame(of: probe)
        record("cut-off click", before, after)
        XCTAssertEqual(after.minY, before.minY, accuracy: 1, "the grid moved on a click on a cut-off cell")
    }

    // MARK: - The picker

    @MainActor
    func testPaneChooseOpensThePickerAndPickingSetsTheImage() throws {
        _ = try BackgroundImageFixture.write(named: "Harbor-pane", in: libraryFolder)
        let (app, _) = try launchApp(projects: [], connectCLI: false)
        defer { app.terminate() }
        openPaneSheet(in: app)
        let none = app.buttons["pane-background-sheet.no-image"]
        XCTAssertFalse(none.isEnabled)
        app.buttons["pane-background-sheet.choose-image"].click()
        expectPicker(in: app)
        waitForPicture("Harbor-pane", in: app)
        cell("Harbor-pane", in: app).click()
        XCTAssertTrue(waitFor({ !self.element("background-images.picker.root", in: app).exists }, timeout: 5), "the picker stayed open")
        XCTAssertTrue(waitFor({ none.isEnabled }, timeout: 10), "the pick did not set an image")
        app.buttons["pane-background-sheet.done"].click()
    }

    @MainActor
    func testSessionChooseOpensThePicker() throws {
        let (app, _) = try launchApp(projects: [], connectCLI: false)
        defer { app.terminate() }
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'session-row.'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.rightClick()
        let item = app.menuItems.matching(NSPredicate(format: "title BEGINSWITH 'Set Session Background'")).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        item.click()
        let custom = app.buttons["session-background-sheet.custom"]
        XCTAssertTrue(custom.waitForExistence(timeout: 5))
        custom.click()
        app.buttons["session-background-sheet.choose-image"].click()
        expectPicker(in: app)
    }

    @MainActor
    func testSettingsChooseOpensThePicker() throws {
        let (app, _) = try launchApp(projects: [], connectCLI: false)
        defer { app.terminate() }
        openSettingsAppearance(in: app)
        let choose = app.buttons["appearance-background.choose-image"]
        XCTAssertTrue(choose.waitForExistence(timeout: 5))
        choose.click()
        expectPicker(in: app)
    }

    @MainActor
    func testProjectChooseCopiesThePickIntoProjectBackgrounds() throws {
        _ = try BackgroundImageFixture.write(named: "Harbor-copy", in: libraryFolder)
        let existing = ProjectFixture.project(
            name: "Existing", root: try makeDirectory("existing-root"), layout: ProjectFixture.terminal(), preset: "singlePane"
        )
        let (app, _) = try launchApp(projects: [existing], connectCLI: false)
        defer { app.terminate() }
        let fileMenu = openMenu("File", in: app)
        menuItem("Edit Projects", in: fileMenu).click()
        let edit = element("project-editor.background.edit", in: app)
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        edit.click()
        let custom = app.buttons["project-background-sheet.custom"]
        XCTAssertTrue(custom.waitForExistence(timeout: 5))
        custom.click()
        app.buttons["project-background-sheet.choose-image"].click()
        expectPicker(in: app)
        waitForPicture("Harbor-copy", in: app)
        cell("Harbor-copy", in: app).click()
        let none = app.buttons["project-background-sheet.no-image"]
        XCTAssertTrue(waitFor({ none.isEnabled }, timeout: 10), "the pick did not set an image")
        app.buttons["project-background-sheet.done"].click()
        element("project-editor.save", in: app).click()
        XCTAssertTrue(waitFor({
            let background = ProjectFixture.read(self.storeFile)?.first?["background"] as? [String: Any]
            return (background?["imagePath"] as? String)?.hasPrefix(self.projectFolder.path) == true
        }, timeout: 10), "the saved path isn't in ProjectBackgrounds")
    }

    @MainActor
    func testPickerOffersAddFromFileAndCancelLeavesTheImageAlone() throws {
        let (app, _) = try launchApp(projects: [], connectCLI: false)
        defer { app.terminate() }
        openPaneSheet(in: app)
        app.buttons["pane-background-sheet.choose-image"].click()
        expectPicker(in: app)
        XCTAssertTrue(app.buttons["background-images.add"].exists)
        app.buttons["background-images.picker.cancel"].click()
        XCTAssertTrue(waitFor({ !self.element("background-images.picker.root", in: app).exists }, timeout: 5))
        XCTAssertFalse(app.buttons["pane-background-sheet.no-image"].isEnabled)
    }
}
