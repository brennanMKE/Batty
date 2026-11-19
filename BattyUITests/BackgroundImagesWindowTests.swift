// BackgroundImagesWindowTests.swift

import XCTest

/// The Background Images picker (#0552), which opens from Pane > Background
/// Images… and each background control's Choose… (#0629: there is no
/// standalone window). The library sits beside the isolated `projects.json`. Assertions go by named cell, never by total count,
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
    private func pickerRoot(in app: XCUIApplication) -> XCUIElement {
        element("background-images.picker.root", in: app)
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

    /// The picker opens on Background Sets unless the current image is in
    /// My Images. The segment's action also focuses the grid.
    @MainActor
    private func showMyImages(in app: XCUIApplication) {
        let tab = app.radioButtons["My Images"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 5), "no My Images tab")
        tab.click()
    }

    // MARK: - Entry points

    @MainActor
    func testPaneMenuOpensThePickerAndPickingSetsThePanesImage() throws {
        _ = try BackgroundImageFixture.write(named: "Harbor-menu", in: libraryFolder)
        let (app, _) = try launchApp(projects: [], connectCLI: false)
        defer { app.terminate() }
        openPaneBackgroundPicker(in: app)
        showMyImages(in: app)
        waitForPicture("Harbor-menu", in: app)
        cell("Harbor-menu", in: app).doubleClick()
        XCTAssertTrue(waitFor({ !self.pickerRoot(in: app).exists }, timeout: 10), "the picker stayed open")
        let disclosure = app.descendants(matching: .disclosureTriangle).firstMatch
        XCTAssertTrue(disclosure.waitForExistence(timeout: 5))
        disclosure.click()
        let gear = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'pane-background-settings.'")).firstMatch
        XCTAssertTrue(gear.waitForExistence(timeout: 5))
        gear.click()
        let custom = app.buttons["pane-background-sheet.custom"]
        XCTAssertTrue(custom.waitForExistence(timeout: 5))
        XCTAssertEqual(custom.value as? String, "selected", "the Pane still follows")
        XCTAssertTrue(waitFor({ app.buttons["pane-background-sheet.no-image"].isEnabled }, timeout: 10), "the pick did not set the Pane's image")
        app.buttons["pane-background-sheet.done"].click()
    }

    @MainActor
    func testPaneMenuBackgroundImagesIsDisabledOnAViewPane() throws {
        let (app, _) = try launchApp(projects: [], connectCLI: false)
        defer { app.terminate() }
        let paneMenu = openMenu("Pane", in: app)
        let open = paneMenu.children(matching: .menuItem)["Process Status"]
        XCTAssertTrue(open.waitForExistence(timeout: 5), "Pane menu has no Process Status item: \(menuTitles(paneMenu))")
        open.click()
        let view = element("process-status-view", in: app)
        XCTAssertTrue(view.waitForExistence(timeout: 20), "Process Status did not open")
        view.click()
        let menu = openMenu("Pane", in: app)
        let item = menuItem("Background Images", in: menu)
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        XCTAssertFalse(item.isEnabled, "Background Images… is enabled on a view Pane")
        closeMenus(app)
    }

    @MainActor
    func testNoStandaloneBackgroundImagesEntryPoints() throws {
        let (app, _) = try launchApp(projects: [], connectCLI: false)
        defer { app.terminate() }
        let file = openMenu("File", in: app)
        XCTAssertTrue(file.menuItems["Open Project"].waitForExistence(timeout: 5))
        XCTAssertFalse(menuItem("Background Images", in: file).exists, "File still has Background Images: \(menuTitles(file))")
        closeMenus(app)
        openSettingsAppearance(in: app)
        XCTAssertTrue(app.buttons["appearance-background.choose-image"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["appearance-background.manage-images"].exists, "Settings still has Manage Images…")
    }

    // MARK: - Showing and removing images

    @MainActor
    func testAnImageShowsItsThumbnailNameAndSize() throws {
        _ = try BackgroundImageFixture.write(named: "Harbor-show", in: libraryFolder)
        let (app, _) = try launchApp(projects: [], connectCLI: false)
        defer { app.terminate() }
        openPaneBackgroundPicker(in: app)
        showMyImages(in: app)
        waitForPicture("Harbor-show", in: app)
        XCTAssertTrue(element("background-images.cell.Harbor-show.size", in: app).exists)
        XCTAssertEqual(element("background-images.cell.Harbor-show.uses", in: app).value as? String, "Not in use")
    }

    /// A click picks, so the context menu is how a pointer removes an image.
    @MainActor
    func testRemovingAnUnusedImageRemovesItsCell() throws {
        let path = try BackgroundImageFixture.write(named: "Harbor-remove", in: libraryFolder)
        let (app, _) = try launchApp(projects: [], connectCLI: false)
        defer { app.terminate() }
        openPaneBackgroundPicker(in: app)
        showMyImages(in: app)
        waitForPicture("Harbor-remove", in: app)
        cell("Harbor-remove", in: app).rightClick()
        let remove = app.menuItems["Remove…"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5), "the cell has no Remove… menu item")
        remove.click()
        let confirm = app.buttons["background-images.confirm-remove"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.click()
        XCTAssertTrue(waitFor({ !self.cell("Harbor-remove", in: app).exists }, timeout: 10), "the cell stayed")
        XCTAssertTrue(pickerRoot(in: app).exists, "the picker closed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    @MainActor
    func testRemovingAProjectsImageListsTheProjectAndClearsItsPath() throws {
        let path = try BackgroundImageFixture.write(named: "Harbor-project", in: projectFolder)
        let (app, _) = try launchApp(projects: [try project(name: "Uses Image", imagePath: path)], connectCLI: false)
        defer { app.terminate() }
        openPaneBackgroundPicker(in: app)
        showMyImages(in: app)
        waitForPicture("Harbor-project", in: app)
        XCTAssertEqual(element("background-images.cell.Harbor-project.uses", in: app).value as? String, "Project Uses Image")
        requestRemoval(of: "Harbor-project", in: app) { app.buttons["background-images.remove"].click() }
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

    @MainActor
    func testDeleteKeyRemovesTheSelectedImageInThePicker() throws {
        let path = try BackgroundImageFixture.write(named: "Harbor-delete", in: libraryFolder)
        let (app, _) = try launchApp(projects: [], connectCLI: false)
        defer { app.terminate() }
        openPaneBackgroundPicker(in: app)
        showMyImages(in: app)
        waitForPicture("Harbor-delete", in: app)
        requestRemoval(of: "Harbor-delete", in: app) { app.typeKey(.delete, modifierFlags: []) }
        app.buttons["background-images.confirm-remove"].click()
        XCTAssertTrue(waitFor({ !self.cell("Harbor-delete", in: app).exists }, timeout: 10), "the cell stayed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    /// Selects by arrow key, since a click picks, and asks to remove with
    /// `trigger`. The app-wide folder scanned here is the guest's real one, so
    /// the fixture may not be the first cell: until the dialog names `name`,
    /// it is dismissed and the next cell selected. The step count only bounds
    /// a regression. Returns with the dialog for `name` up.
    @MainActor
    private func requestRemoval(of name: String, in app: XCUIApplication, using trigger: () -> Void) {
        let confirm = app.buttons["background-images.confirm-remove"]
        let title = app.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", "Remove \(name)?", "Remove \(name)?")).firstMatch
        app.typeKey(.rightArrow, modifierFlags: [])
        XCTAssertTrue(waitFor({ app.buttons["background-images.remove"].isEnabled }, timeout: 5), "the arrow key selected nothing")
        for _ in 0..<40 {
            trigger()
            XCTAssertTrue(confirm.waitForExistence(timeout: 5), "Remove asked nothing")
            if title.waitForExistence(timeout: 1) { return }
            app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
            XCTAssertTrue(waitFor({ !confirm.exists }, timeout: 5), "the dialog stayed")
            app.typeKey(.rightArrow, modifierFlags: [])
        }
        XCTFail("the arrow keys never reached \(name)")
    }

    /// A fresh launch, so this is the first open: the grid only exists once the
    /// scan has finished, and no click has given it focus.
    @MainActor
    func testArrowKeySelectsACellOnTheFirstOpen() throws {
        _ = try BackgroundImageFixture.write(named: "Harbor-keys", in: libraryFolder)
        let (app, _) = try launchApp(projects: [], connectCLI: false)
        defer { app.terminate() }
        openPaneBackgroundPicker(in: app)
        showMyImages(in: app)
        waitForPicture("Harbor-keys", in: app)
        let remove = app.buttons["background-images.remove"]
        XCTAssertFalse(remove.isEnabled)
        app.typeKey(.rightArrow, modifierFlags: [])
        XCTAssertTrue(waitFor({ remove.isEnabled }, timeout: 5), "the arrow key selected nothing")
    }

    // MARK: - Selecting keeps the grid still

    private static let jumpNames = (0..<24).map { String(format: "Jump-%02d", $0) }

    /// 24 images make eight rows at the picker's 3 columns, so the grid scrolls.
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

    /// The grid lists the newest image first and builds only the cells near
    /// the visible rows, so no one fixture name is sure to exist on open.
    @MainActor
    private func anyJumpCell(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'background-images.cell.Jump-'")).firstMatch
    }

    @MainActor
    private func scrollGridDown(in app: XCUIApplication) {
        let root = pickerRoot(in: app)
        XCTAssertTrue(root.waitForExistence(timeout: 5))
        root.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)).hover()
        for _ in 0..<2 { root.scroll(byDeltaX: 0, deltaY: -240) }
        _ = settledFrame(of: anyJumpCell(in: app))
    }

    /// Cells wholly inside the grid: below the picker's title and tabs, above
    /// its bottom bar.
    @MainActor
    private func visibleJumpCells(in app: XCUIApplication) -> [XCUIElement] {
        let frame = pickerRoot(in: app).frame
        let bounds = CGRect(x: frame.minX, y: frame.minY + 100, width: frame.width, height: frame.height - 160)
        return Self.jumpNames.map { cell($0, in: app) }.filter { cell in
            cell.exists && cell.isHittable && bounds.contains(cell.frame)
        }
    }

    /// A click picks and closes the picker, so selection here is by arrow key.
    @MainActor
    func testArrowKeySelectionAfterScrollingKeepsTheGridStill() throws {
        try seedScrollingLibrary()
        let (app, _) = try launchApp(projects: [], connectCLI: false)
        defer { app.terminate() }
        app.activate()
        XCTAssertEqual(app.state, .runningForeground, "Batty is not frontmost")
        openPaneBackgroundPicker(in: app)
        showMyImages(in: app)
        XCTAssertTrue(anyJumpCell(in: app).waitForExistence(timeout: 10), "the grid never showed")
        scrollGridDown(in: app)
        let visible = visibleJumpCells(in: app)
        XCTAssertGreaterThanOrEqual(visible.count, 3, "fewer than three whole cells on screen after scrolling")
        guard visible.count >= 3 else { return }
        let probe = visible[visible.count - 1]
        let firstBefore = settledFrame(of: probe)
        app.typeKey(.rightArrow, modifierFlags: [])
        XCTAssertTrue(waitFor({ app.buttons["background-images.remove"].isEnabled }, timeout: 5), "the arrow key selected nothing")
        let firstAfter = settledFrame(of: probe)
        record("first arrow key", firstBefore, firstAfter)
        XCTAssertEqual(firstAfter.minY, firstBefore.minY, accuracy: 1, "the grid moved on the first arrow key")
        let before = settledFrame(of: probe)
        app.typeKey(.rightArrow, modifierFlags: [])
        let after = settledFrame(of: probe)
        record("arrow key", before, after)
        XCTAssertEqual(after.minY, before.minY, accuracy: 1, "the grid moved on an arrow key")
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
        showMyImages(in: app)
        waitForPicture("Harbor-pane", in: app)
        cell("Harbor-pane", in: app).doubleClick()
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
        openEditorFromFileMenu(in: app)
        selectProjectInEditor(named: "Existing", in: app)
        let edit = element("project-editor.background.edit", in: app)
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        edit.click()
        let custom = app.buttons["project-background-sheet.custom"]
        XCTAssertTrue(custom.waitForExistence(timeout: 5))
        custom.click()
        app.buttons["project-background-sheet.choose-image"].click()
        expectPicker(in: app)
        showMyImages(in: app)
        waitForPicture("Harbor-copy", in: app)
        cell("Harbor-copy", in: app).doubleClick()
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
    func testPickerOffersAddFromFileAndDoneLeavesTheImageAlone() throws {
        let (app, _) = try launchApp(projects: [], connectCLI: false)
        defer { app.terminate() }
        openPaneSheet(in: app)
        app.buttons["pane-background-sheet.choose-image"].click()
        expectPicker(in: app)
        showMyImages(in: app)
        XCTAssertTrue(app.buttons["background-images.add"].exists)
        app.buttons["background-images.picker.done"].click()
        XCTAssertTrue(waitFor({ !self.element("background-images.picker.root", in: app).exists }, timeout: 5))
        XCTAssertFalse(app.buttons["pane-background-sheet.no-image"].isEnabled)
    }

    @MainActor
    func testReopeningShowsTheCurrentMyImagesImageSelectedAndInView() throws {
        try seedScrollingLibrary()
        let (app, _) = try launchApp(projects: [], connectCLI: false)
        defer { app.terminate() }
        openPaneSheet(in: app)
        let choose = app.buttons["pane-background-sheet.choose-image"]
        choose.click()
        expectPicker(in: app)
        showMyImages(in: app)
        XCTAssertTrue(anyJumpCell(in: app).waitForExistence(timeout: 10), "the grid never showed")
        // The newest image is listed first, so the oldest is the last cell.
        let name = Self.jumpNames[0]
        let target = cell(name, in: app)
        let root = pickerRoot(in: app)
        root.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)).hover()
        for _ in 0..<30 where !(target.exists && target.isHittable) {
            root.scroll(byDeltaX: 0, deltaY: -120)
        }
        XCTAssertTrue(target.exists && target.isHittable, "no cell for \(name)")
        target.doubleClick()
        XCTAssertTrue(waitFor({ !root.exists }, timeout: 10), "the picker stayed open")
        XCTAssertTrue(waitFor({ app.buttons["pane-background-sheet.no-image"].isEnabled }, timeout: 10), "the pick did not set an image")

        choose.click()
        expectPicker(in: app)
        XCTAssertTrue(app.radioButtons["My Images"].firstMatch.isSelected, "the picker did not open on My Images")
        XCTAssertTrue(waitFor({ target.exists && target.isHittable && target.isSelected }, timeout: 10), "\(name) is not selected and in view")
    }

    @MainActor
    private func openPaneChooser(with name: String, in app: XCUIApplication) -> XCUIElement {
        openPaneSheet(in: app)
        let none = app.buttons["pane-background-sheet.no-image"]
        XCTAssertFalse(none.isEnabled)
        app.buttons["pane-background-sheet.choose-image"].click()
        expectPicker(in: app)
        showMyImages(in: app)
        waitForPicture(name, in: app)
        return none
    }

    @MainActor
    func testSingleClickAppliesTheImageAndKeepsThePickerOpen() throws {
        _ = try BackgroundImageFixture.write(named: "Harbor-single", in: libraryFolder)
        let (app, _) = try launchApp(projects: [], connectCLI: false)
        defer { app.terminate() }
        let none = openPaneChooser(with: "Harbor-single", in: app)
        let target = cell("Harbor-single", in: app)
        target.click()
        XCTAssertTrue(waitFor({ none.isEnabled }, timeout: 10), "the single click did not apply the image")
        XCTAssertTrue(element("background-images.picker.root", in: app).exists, "the picker closed after a single click")
        XCTAssertTrue(target.isSelected)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitFor({ !self.element("background-images.picker.root", in: app).exists }, timeout: 5), "Escape did not close the picker")
        XCTAssertTrue(none.isEnabled, "Escape dropped the clicked image")
        app.buttons["pane-background-sheet.done"].click()
    }

    @MainActor
    func testGearSheetCancelRevertsAnImageAppliedFromThePicker() throws {
        _ = try BackgroundImageFixture.write(named: "Harbor-revert", in: libraryFolder)
        let (app, _) = try launchApp(projects: [], connectCLI: false)
        defer { app.terminate() }
        let none = openPaneChooser(with: "Harbor-revert", in: app)
        cell("Harbor-revert", in: app).click()
        XCTAssertTrue(waitFor({ none.isEnabled }, timeout: 10), "the single click did not apply the image")
        app.buttons["background-images.picker.done"].click()
        XCTAssertTrue(waitFor({ !self.element("background-images.picker.root", in: app).exists }, timeout: 5))
        app.buttons["pane-background-sheet.cancel"].click()
        let gear = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'pane-background-settings.'")).firstMatch
        XCTAssertTrue(gear.waitForExistence(timeout: 5))
        gear.click()
        let custom = app.buttons["pane-background-sheet.custom"]
        XCTAssertTrue(custom.waitForExistence(timeout: 5))
        custom.click()
        XCTAssertFalse(app.buttons["pane-background-sheet.no-image"].isEnabled, "the gear sheet's Cancel kept the image")
    }

    @MainActor
    func testDoubleClickPicksTheImageAndClosesThePicker() throws {
        _ = try BackgroundImageFixture.write(named: "Harbor-double", in: libraryFolder)
        let (app, _) = try launchApp(projects: [], connectCLI: false)
        defer { app.terminate() }
        let none = openPaneChooser(with: "Harbor-double", in: app)
        cell("Harbor-double", in: app).doubleClick()
        XCTAssertTrue(waitFor({ !self.element("background-images.picker.root", in: app).exists }, timeout: 5), "the picker stayed open")
        XCTAssertTrue(waitFor({ none.isEnabled }, timeout: 10), "the pick did not set an image")
        app.buttons["pane-background-sheet.done"].click()
    }

    @MainActor
    func testReturnPicksTheSelectedImageAndClosesThePicker() throws {
        _ = try BackgroundImageFixture.write(named: "Harbor-return", in: libraryFolder)
        let (app, _) = try launchApp(projects: [], connectCLI: false)
        defer { app.terminate() }
        let none = openPaneChooser(with: "Harbor-return", in: app)
        app.typeKey(.rightArrow, modifierFlags: [])
        XCTAssertTrue(waitFor({ self.cell("Harbor-return", in: app).isSelected }, timeout: 5), "the arrow key selected nothing")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(waitFor({ !self.element("background-images.picker.root", in: app).exists }, timeout: 5), "Return did not close the picker")
        XCTAssertTrue(waitFor({ none.isEnabled }, timeout: 10), "Return did not set an image")
        app.buttons["pane-background-sheet.done"].click()
    }
}
