// BackgroundSetsTests.swift

import XCTest

/// The Background Sets tab (#0576), against a catalog served from a local
/// fixture folder. Never the live site.
nonisolated final class BackgroundSetsTests: ProjectsUITestCase {
    private var catalogFolder: URL { scratch.appending(path: "catalog-fixture") }
    private var libraryFolder: URL { storeFile.deletingLastPathComponent().appending(path: "BackgroundImages") }

    @MainActor
    private func launch(omitting: String? = nil) throws -> XCUIApplication {
        try BackgroundCatalogFixture.write(in: catalogFolder, omitting: omitting)
        let (app, _) = try launchApp(
            projects: [],
            connectCLI: false,
            extraEnvironment: [BackgroundCatalogFixture.envVar: catalogFolder.path]
        )
        return app
    }

    @MainActor
    private func showBackgroundSets(in app: XCUIApplication) {
        let tab = app.radioButtons["Background Sets"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 5), "no Background Sets tab")
        tab.click()
    }

    @MainActor
    private func cell(_ id: String, in app: XCUIApplication) -> XCUIElement {
        element("background-sets.cell.\(id)", in: app)
    }

    private func fullSizeRequests() -> [String] {
        let fulls = Set(BackgroundCatalogFixture.setIDs.flatMap(BackgroundCatalogFixture.imageIDs(in:)).map(BackgroundCatalogFixture.fullPath))
        return BackgroundCatalogFixture.requests(in: catalogFolder).filter(fulls.contains)
    }

    private func hostedDigestFoldersInMyImages() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: libraryFolder.path)) ?? []).filter { $0.count == 64 }
    }

    @MainActor
    private func pick(_ id: String, in app: XCUIApplication) {
        XCTAssertTrue(element("background-images.picker.root", in: app).waitForExistence(timeout: 5), "Choose did not open the picker")
        showBackgroundSets(in: app)
        let target = scrollToCell(id, in: app)
        XCTAssertTrue(target.exists && target.isHittable, "no cell for \(id)")
        target.click()
    }

    /// The sheet is too short for every set, and the lazy grid builds a cell
    /// only near the visible rows, so scroll down a step at a time until the
    /// cell is on screen. The step count only bounds a regression.
    @MainActor
    private func scrollToCell(_ id: String, in app: XCUIApplication) -> XCUIElement {
        let root = element("background-sets.root", in: app)
        XCTAssertTrue(root.waitForExistence(timeout: 5), "no Background Sets view")
        let firstSet = BackgroundCatalogFixture.setIDs[0]
        XCTAssertTrue(element("background-sets.set.\(BackgroundCatalogFixture.setName(firstSet))", in: app).waitForExistence(timeout: 10), "the catalog did not load")
        let target = cell(id, in: app)
        root.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).hover()
        for _ in 0..<30 where !(target.exists && target.isHittable) {
            root.scroll(byDeltaX: 0, deltaY: -120)
        }
        return target
    }

    @MainActor
    func testBackgroundSetsShowsTheSetsWithoutFetchingAFullSizeImage() throws {
        let app = try launch()
        defer { app.terminate() }
        XCTAssertTrue(BackgroundCatalogFixture.requests(in: catalogFolder).isEmpty, "a request was made before Background Sets was shown")
        let menu = openMenu("File", in: app)
        menuItem("Background Images", in: menu).click()
        showBackgroundSets(in: app)
        for set in BackgroundCatalogFixture.setIDs {
            XCTAssertTrue(element("background-sets.set.\(BackgroundCatalogFixture.setName(set))", in: app).waitForExistence(timeout: 10), "no section for \(set)")
            for id in BackgroundCatalogFixture.imageIDs(in: set) {
                XCTAssertTrue(cell(id, in: app).waitForExistence(timeout: 10), "no cell for \(id)")
            }
        }
        XCTAssertTrue(BackgroundCatalogFixture.requests(in: catalogFolder).contains("catalog.json"))
        XCTAssertEqual(fullSizeRequests(), [])
        XCTAssertEqual(hostedDigestFoldersInMyImages(), [])
    }

    @MainActor
    func testChoosingAHostedImageInSettingsDownloadsAndAppliesIt() throws {
        let app = try launch()
        defer { app.terminate() }
        app.typeKey(",", modifierFlags: [.command])
        let appearance = app.toolbars.buttons["Appearance"]
        XCTAssertTrue(appearance.waitForExistence(timeout: 10))
        appearance.click()
        let choose = app.buttons["appearance-background.choose-image"]
        XCTAssertTrue(choose.waitForExistence(timeout: 5))
        choose.click()
        pick("cool-vehicles-01", in: app)
        XCTAssertTrue(waitFor({ !self.element("background-images.picker.root", in: app).exists }, timeout: 15), "the picker stayed open")
        XCTAssertEqual(fullSizeRequests(), [BackgroundCatalogFixture.fullPath("cool-vehicles-01")])
        XCTAssertTrue(waitFor({ app.buttons["appearance-background.no-image"].isEnabled }, timeout: 10), "the pick did not set an image")
        XCTAssertEqual(hostedDigestFoldersInMyImages(), [])
    }

    @MainActor
    func testChoosingAHostedImageForAPaneAppliesIt() throws {
        let app = try launch()
        defer { app.terminate() }
        let disclosure = app.descendants(matching: .disclosureTriangle).firstMatch
        XCTAssertTrue(disclosure.waitForExistence(timeout: 5))
        disclosure.click()
        let gear = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'pane-background-settings.'")).firstMatch
        XCTAssertTrue(gear.waitForExistence(timeout: 5))
        gear.click()
        let custom = app.buttons["pane-background-sheet.custom"]
        XCTAssertTrue(custom.waitForExistence(timeout: 5))
        custom.click()
        let none = app.buttons["pane-background-sheet.no-image"]
        app.buttons["pane-background-sheet.choose-image"].click()
        pick("future-cities-02", in: app)
        XCTAssertTrue(waitFor({ !self.element("background-images.picker.root", in: app).exists }, timeout: 15), "the picker stayed open")
        XCTAssertTrue(waitFor({ none.isEnabled }, timeout: 10), "the pick did not set an image")
        app.buttons["pane-background-sheet.done"].click()
    }

    @MainActor
    func testAFailedDownloadKeepsThePreviousBackground() throws {
        let missing = "beautiful-landscapes-02"
        let app = try launch(omitting: missing)
        defer { app.terminate() }
        app.typeKey(",", modifierFlags: [.command])
        let appearance = app.toolbars.buttons["Appearance"]
        XCTAssertTrue(appearance.waitForExistence(timeout: 10))
        appearance.click()
        let none = app.buttons["appearance-background.no-image"]
        let hadImage = none.waitForExistence(timeout: 5) && none.isEnabled
        app.buttons["appearance-background.choose-image"].click()
        pick(missing, in: app)
        XCTAssertTrue(element("background-sets.cell.\(missing).failed", in: app).waitForExistence(timeout: 15), "the cell showed no failure")
        XCTAssertTrue(element("background-images.picker.root", in: app).exists, "the picker closed after a failure")
        app.buttons["background-images.picker.cancel"].click()
        XCTAssertTrue(waitFor({ !self.element("background-images.picker.root", in: app).exists }, timeout: 5))
        XCTAssertEqual(none.isEnabled, hadImage, "the background changed after a failed download")
    }

    @MainActor
    func testAFailedDownloadCellLinesUpWithItsRowNeighbour() throws {
        let missing = "beautiful-landscapes-02"
        let app = try launch(omitting: missing)
        defer { app.terminate() }
        _ = openSettingsChooser(in: app)
        app.buttons["appearance-background.choose-image"].click()
        pick(missing, in: app)
        XCTAssertTrue(element("background-sets.cell.\(missing).failed", in: app).waitForExistence(timeout: 15), "the cell showed no failure")
        let cell01 = cell("beautiful-landscapes-01", in: app)
        let cell02 = cell(missing, in: app)
        XCTAssertTrue(cell01.exists)
        XCTAssertTrue(cell02.exists)
        XCTAssertLessThanOrEqual(cell01.frame.maxX, cell02.frame.minX, "the sheet is too narrow for two columns")
        XCTAssertEqual(cell01.frame.minY, cell02.frame.minY, accuracy: 0.5, "the failed cell's picture does not line up with its neighbour")
        app.buttons["background-images.picker.cancel"].click()
        XCTAssertTrue(waitFor({ !self.element("background-images.picker.root", in: app).exists }, timeout: 5))
    }

    @MainActor
    private func openSettingsChooser(in app: XCUIApplication) -> XCUIElement {
        app.typeKey(",", modifierFlags: [.command])
        let appearance = app.toolbars.buttons["Appearance"]
        XCTAssertTrue(appearance.waitForExistence(timeout: 10))
        appearance.click()
        let none = app.buttons["appearance-background.no-image"]
        XCTAssertTrue(none.waitForExistence(timeout: 5))
        return none
    }

    @MainActor
    func testClickingADownloadingImageAgainCancelsIt() throws {
        let id = "cool-vehicles-01"
        let app = try launch()
        defer { app.terminate() }
        try BackgroundCatalogFixture.hold(id, in: catalogFolder)
        defer { BackgroundCatalogFixture.release(id, in: catalogFolder) }
        let none = openSettingsChooser(in: app)
        let hadImage = none.isEnabled
        app.buttons["appearance-background.choose-image"].click()
        pick(id, in: app)
        let progress = element("background-sets.cell.\(id).progress", in: app)
        XCTAssertTrue(progress.waitForExistence(timeout: 10), "no spinner over the downloading cell")
        XCTAssertFalse(element("background-sets.cell.\(id).cancel", in: app).exists, "the cell still shows a Cancel button")
        cell(id, in: app).click()
        XCTAssertTrue(waitFor({ !progress.exists }, timeout: 10), "the second click did not cancel the download")
        XCTAssertTrue(element("background-images.picker.root", in: app).exists, "the picker closed after a cancel")
        BackgroundCatalogFixture.release(id, in: catalogFolder)
        Thread.sleep(forTimeInterval: 1)
        XCTAssertTrue(element("background-images.picker.root", in: app).exists, "the cancelled pick was applied")
        app.buttons["background-images.picker.cancel"].click()
        XCTAssertTrue(waitFor({ !self.element("background-images.picker.root", in: app).exists }, timeout: 5))
        XCTAssertEqual(none.isEnabled, hadImage, "the background changed after a cancelled download")
    }

    @MainActor
    func testClickingAnotherImageWhileOneDownloadsAppliesTheNewOne() throws {
        let first = "cool-vehicles-01", second = "cool-vehicles-02"
        let app = try launch()
        defer { app.terminate() }
        try BackgroundCatalogFixture.hold(first, in: catalogFolder)
        defer { BackgroundCatalogFixture.release(first, in: catalogFolder) }
        let none = openSettingsChooser(in: app)
        app.buttons["appearance-background.choose-image"].click()
        pick(first, in: app)
        XCTAssertTrue(element("background-sets.cell.\(first).progress", in: app).waitForExistence(timeout: 10), "no spinner over the downloading cell")
        cell(second, in: app).click()
        XCTAssertTrue(waitFor({ !self.element("background-images.picker.root", in: app).exists }, timeout: 15), "the picker stayed open")
        let requests = fullSizeRequests()
        XCTAssertTrue(requests.contains(BackgroundCatalogFixture.fullPath(first)))
        XCTAssertTrue(requests.contains(BackgroundCatalogFixture.fullPath(second)))
        XCTAssertTrue(waitFor({ none.isEnabled }, timeout: 10), "the pick did not set an image")
    }
}
