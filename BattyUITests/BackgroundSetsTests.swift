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
        openPaneBackgroundPicker(in: app)
        showBackgroundSets(in: app)
        let root = element("background-sets.root", in: app)
        XCTAssertTrue(element("background-sets.set.\(BackgroundCatalogFixture.setName(BackgroundCatalogFixture.setIDs[0]))", in: app).waitForExistence(timeout: 10), "the catalog did not load")
        // The picker shows about two sets; the lazy grid builds the rest as
        // they scroll in, so each cell is scrolled to in catalog order.
        root.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).hover()
        for set in BackgroundCatalogFixture.setIDs {
            for id in BackgroundCatalogFixture.imageIDs(in: set) {
                let target = cell(id, in: app)
                for _ in 0..<30 where !(target.exists && target.isHittable) {
                    root.scroll(byDeltaX: 0, deltaY: -120)
                }
                XCTAssertTrue(target.exists, "no cell for \(id)")
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

    @MainActor
    private func showBackgroundSetsPicker(in app: XCUIApplication) {
        openPaneBackgroundPicker(in: app)
        showBackgroundSets(in: app)
        for set in BackgroundCatalogFixture.setIDs {
            XCTAssertTrue(setSection(set, in: app).waitForExistence(timeout: 10), "no section for \(set)")
        }
    }

    @MainActor
    private func setSection(_ id: String, in app: XCUIApplication) -> XCUIElement {
        element("background-sets.set.\(BackgroundCatalogFixture.setName(id))", in: app)
    }

    @MainActor
    func testRefreshPicksUpASetAddedToTheCatalog() throws {
        let app = try launch()
        defer { app.terminate() }
        showBackgroundSetsPicker(in: app)
        try BackgroundCatalogFixture.write(in: catalogFolder, sets: BackgroundCatalogFixture.setIDs + ["deep-space"])
        XCTAssertFalse(setSection("deep-space", in: app).exists, "the new set showed before Refresh")
        element("background-sets.refresh", in: app).click()
        XCTAssertTrue(setSection("deep-space", in: app).waitForExistence(timeout: 10), "Refresh did not pick up the new set")
    }

    @MainActor
    func testFilterNarrowsToMatchingSetsAndImages() throws {
        let app = try launch()
        defer { app.terminate() }
        showBackgroundSetsPicker(in: app)
        let field = element("background-sets.filter", in: app)
        field.click()
        field.typeText("COOL")
        XCTAssertTrue(setSection("cool-vehicles", in: app).waitForExistence(timeout: 5))
        XCTAssertFalse(setSection("future-cities", in: app).exists)
        XCTAssertFalse(setSection("beautiful-landscapes", in: app).exists)

        field.typeKey("a", modifierFlags: .command)
        field.typeText("cities-02")
        XCTAssertTrue(setSection("future-cities", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(cell("future-cities-02", in: app).waitForExistence(timeout: 5))
        XCTAssertFalse(cell("future-cities-01", in: app).exists)
        XCTAssertFalse(setSection("cool-vehicles", in: app).exists)
    }

    @MainActor
    func testFilterWithNoMatchesShowsTheEmptyStateAndClearingRestoresTheGrid() throws {
        let app = try launch()
        defer { app.terminate() }
        showBackgroundSetsPicker(in: app)
        let field = element("background-sets.filter", in: app)
        field.click()
        field.typeText("zzz")
        XCTAssertTrue(element("background-sets.no-matches", in: app).waitForExistence(timeout: 5))
        for set in BackgroundCatalogFixture.setIDs {
            XCTAssertFalse(setSection(set, in: app).exists, "\(set) still shows")
        }
        element("background-sets.filter.clear", in: app).click()
        for set in BackgroundCatalogFixture.setIDs {
            XCTAssertTrue(setSection(set, in: app).waitForExistence(timeout: 5), "\(set) did not come back")
        }
        XCTAssertFalse(element("background-sets.no-matches", in: app).exists)
    }

    /// The frame once two reads in a row agree. The timeout only bounds a regression.
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

    @MainActor
    private func record(_ label: String, _ before: CGRect, _ after: CGRect) {
        let attachment = XCTAttachment(string: "\(label): before \(before) after \(after)")
        attachment.name = "jump-measure \(label)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// A click picks; both downloads are held so the picker stays open while
    /// the grid is measured.
    @MainActor
    func testSelectingASetImageAfterScrollingKeepsTheGridStill() throws {
        let app = try launch()
        defer { app.terminate() }
        for id in ["beautiful-landscapes-01", "beautiful-landscapes-02"] {
            try BackgroundCatalogFixture.hold(id, in: catalogFolder)
        }
        defer {
            for id in ["beautiful-landscapes-01", "beautiful-landscapes-02"] {
                BackgroundCatalogFixture.release(id, in: catalogFolder)
            }
        }
        showBackgroundSetsPicker(in: app)
        let target = scrollToCell("beautiful-landscapes-01", in: app)
        XCTAssertTrue(target.exists && target.isHittable, "no cell for beautiful-landscapes-01")
        let neighbour = cell("beautiful-landscapes-02", in: app)
        XCTAssertTrue(neighbour.exists)

        let neighbourBefore = settledFrame(of: neighbour)
        target.click()
        let neighbourAfter = settledFrame(of: neighbour)
        record("sets first click", neighbourBefore, neighbourAfter)
        XCTAssertEqual(neighbourAfter.minY, neighbourBefore.minY, accuracy: 1, "the grid moved on the first click")

        let targetBefore = settledFrame(of: target)
        neighbour.click()
        let targetAfter = settledFrame(of: target)
        record("sets later click", targetBefore, targetAfter)
        XCTAssertEqual(targetAfter.minY, targetBefore.minY, accuracy: 1, "the grid moved on a later click")
        XCTAssertTrue(element("background-images.picker.root", in: app).exists, "the picker closed, so a pick finished")
        app.buttons["background-images.picker.cancel"].click()
    }

    private struct ShippedBottom {
        let app: XCUIApplication
        let root: XCUIElement
        let deepSpace: XCUIElement
        let galaxy: XCUIElement
    }

    /// A fresh open of Pane > Background Images… with the shipped catalog,
    /// Background Sets scrolled to the bottom so Deep Space's heading is above
    /// the view. `downloaded` are shipped full paths seeded as already
    /// downloaded; `waitForAvailable` is a cell stem whose "Available offline"
    /// line must show before the bottom is measured. `checkInFlight` holds
    /// `catalog.json`, then switches to My Images and back, so Background Sets
    /// appearing starts a catalog check that stays in flight while the grid
    /// scrolls; it needs a check interval of 0.
    @MainActor
    private func openShippedAtTheBottom(
        downloaded: [String] = [],
        waitForAvailable: String? = nil,
        environment: [String: String] = [:],
        checkInFlight: Bool = false
    ) throws -> ShippedBottom {
        try BackgroundCatalogFixture.writeShipped(in: catalogFolder)
        if !downloaded.isEmpty {
            try BackgroundCatalogFixture.seedDownloaded(downloaded, into: libraryFolder.appending(path: "Hosted"))
        }
        let (app, _) = try launchApp(
            projects: [],
            connectCLI: false,
            extraEnvironment: [BackgroundCatalogFixture.envVar: catalogFolder.path].merging(environment) { _, new in new }
        )
        app.activate()
        XCTAssertEqual(app.state, .runningForeground, "Batty is not frontmost")
        let picker = openPaneBackgroundPicker(in: app)
        showBackgroundSets(in: app)
        let root = element("background-sets.root", in: app)
        XCTAssertTrue(root.waitForExistence(timeout: 5), "no Background Sets view")
        let deepSpace = element("background-sets.set.Deep Space", in: app)
        let galaxy = cell("08-distant-galaxy", in: app)
        XCTAssertTrue(element("background-sets.set.Future Cities", in: app).waitForExistence(timeout: 10), "the catalog did not load")

        if checkInFlight {
            let refresh = element("background-sets.refresh", in: app)
            XCTAssertTrue(waitFor({ refresh.isEnabled }, timeout: 10), "a catalog check never finished")
            try Data().write(to: catalogFolder.appending(path: "catalog.json.hold"))
            app.radioButtons["My Images"].firstMatch.click()
            showBackgroundSets(in: app)
            XCTAssertTrue(waitFor({ !refresh.isEnabled }, timeout: 5), "Background Sets appearing started no catalog check")
            XCTAssertTrue(element("background-sets.set.Future Cities", in: app).waitForExistence(timeout: 5), "the sets did not show during the check")
        }

        let available = waitForAvailable.map { element("background-sets.cell.\($0).available", in: app) }
        var sawAvailable = available?.exists ?? true
        root.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).hover()
        for _ in 0..<40 where !(galaxy.exists && galaxy.isHittable) {
            root.scroll(byDeltaX: 0, deltaY: -240)
            sawAvailable = sawAvailable || (available?.exists ?? true)
        }
        for _ in 0..<5 { root.scroll(byDeltaX: 0, deltaY: -240) }
        if let available, !sawAvailable {
            sawAvailable = available.waitForExistence(timeout: 5)
        }
        XCTAssertTrue(sawAvailable, "no Available offline line, so the seeded downloads were not picked up")
        XCTAssertTrue(galaxy.exists && galaxy.isHittable, "Distant Galaxy never came on screen")
        record("picker", picker.frame, root.frame)
        return ShippedBottom(app: app, root: root, deepSpace: deepSpace, galaxy: galaxy)
    }

    /// Keeps the download of a shipped Deep Space image in flight, so a click
    /// on it starts a pick that leaves the picker open.
    private func holdDeepSpace(_ stems: [String]) throws {
        for stem in stems {
            try Data().write(to: catalogFolder.appending(path: "deep-space/\(stem).png.hold"))
        }
    }

    private func releaseDeepSpace(_ stems: [String]) {
        for stem in stems {
            try? FileManager.default.removeItem(at: catalogFolder.appending(path: "deep-space/\(stem).png.hold"))
        }
    }

    /// Frames of Distant Galaxy, its visible row neighbours and the Deep Space
    /// section, read before and after `action`, each recorded as a
    /// `jump-measure` attachment.
    @MainActor
    /// `accuracy` 0 asks for the same whole-point frame, which is how XCUITest
    /// reports it.
    private func assertBottomStill(_ bottom: ShippedBottom, _ label: String, accuracy: CGFloat = 1, during action: () -> Void) {
        let neighbours = ["05-engine-trail", "06-ring-station", "07-fleet-dust-lane"].map { cell($0, in: bottom.app) }
            .filter { $0.exists && $0.isHittable }
        let galaxyBefore = settledFrame(of: bottom.galaxy)
        let neighboursBefore = neighbours.map(\.frame)
        let headerBefore = bottom.deepSpace.exists ? bottom.deepSpace.frame : .null
        XCTAssertLessThan(headerBefore.minY, bottom.root.frame.minY, "Deep Space's heading is still in view, so this isn't the reported layout")
        action()
        let galaxyAfter = settledFrame(of: bottom.galaxy)
        record("\(label) Distant Galaxy", galaxyBefore, galaxyAfter)
        record("\(label) Deep Space section", headerBefore, bottom.deepSpace.exists ? bottom.deepSpace.frame : .null)
        XCTAssertEqual(galaxyAfter.minY, galaxyBefore.minY, accuracy: accuracy, "\(label): Distant Galaxy moved")
        for (neighbour, before) in zip(neighbours, neighboursBefore) {
            let after = neighbour.frame
            record("\(label) \(neighbour.identifier)", before, after)
            XCTAssertEqual(after.minY, before.minY, accuracy: accuracy, "\(label): \(neighbour.identifier) moved")
        }
    }

    /// #0624's report: a fresh open, Background Sets with the shipped catalog,
    /// scrolled to the bottom, then a click on the last image.
    @MainActor
    func testClickingTheLastShippedImageAtTheBottomKeepsTheGridStill() throws {
        let bottom = try openShippedAtTheBottom()
        defer { bottom.app.terminate() }
        try holdDeepSpace(["08-distant-galaxy"])
        defer { releaseDeepSpace(["08-distant-galaxy"]) }
        assertBottomStill(bottom, "click") { bottom.galaxy.click() }
    }

    /// Some images in the sets above Deep Space downloaded, so the rows above the
    /// view differ in height from each other and from the visible ones.
    private static let unevenAboveDeepSpace = [
        "future-cities/01-skyline-fog.png", "future-cities/02-canal-after-rain.png", "future-cities/05-desert-dome.png",
        "cool-vehicles/01-cafe-racer-garage.png", "cool-vehicles/02-expedition-truck-salt-flat.png", "cool-vehicles/05-electric-bike-rooftop.png",
        "beautiful-landscapes/01-mountain-lake-blue-hour.png", "beautiful-landscapes/02-dunes-dusk.png", "beautiful-landscapes/05-sea-cliffs-overcast.png",
    ]

    @MainActor
    func testClickingTheLastShippedImageWithDownloadedImagesAboveKeepsTheGridStill() throws {
        let bottom = try openShippedAtTheBottom(downloaded: Self.unevenAboveDeepSpace, waitForAvailable: "05-sea-cliffs-overcast")
        defer { bottom.app.terminate() }
        try holdDeepSpace(["08-distant-galaxy", "05-engine-trail"])
        defer { releaseDeepSpace(["08-distant-galaxy", "05-engine-trail"]) }
        assertBottomStill(bottom, "first click") { bottom.galaxy.click() }
        let trail = cell("05-engine-trail", in: bottom.app)
        XCTAssertTrue(trail.exists && trail.isHittable, "Engine Trail is not on screen")
        assertBottomStill(bottom, "later click") { trail.click() }
    }

    /// A click on a downloaded image picks it and closes the picker, so the
    /// clicks go to Distant Galaxy, held, with its row neighbours downloaded:
    /// the first starts its download, the second cancels it.
    @MainActor
    func testClickingAtTheBottomWithDownloadedImagesInView() throws {
        let inView = ["05-engine-trail", "06-ring-station", "07-fleet-dust-lane"].map { "deep-space/\($0).png" }
        let bottom = try openShippedAtTheBottom(downloaded: inView, waitForAvailable: "07-fleet-dust-lane")
        defer { bottom.app.terminate() }
        try holdDeepSpace(["08-distant-galaxy"])
        defer { releaseDeepSpace(["08-distant-galaxy"]) }
        let progress = element("background-sets.cell.08-distant-galaxy.progress", in: bottom.app)
        assertBottomStill(bottom, "first click") {
            bottom.galaxy.click()
            XCTAssertTrue(progress.waitForExistence(timeout: 5), "the click started no download")
        }
        assertBottomStill(bottom, "cancelling click") {
            bottom.galaxy.click()
            XCTAssertTrue(waitFor({ !progress.exists }, timeout: 5), "the second click did not cancel the download")
        }
        XCTAssertTrue(element("background-images.picker.root", in: bottom.app).exists, "the picker closed")
    }

    @MainActor
    func testCatalogCheckAtTheBottomKeepsTheGridStill() throws {
        let bottom = try openShippedAtTheBottom(downloaded: Self.unevenAboveDeepSpace, waitForAvailable: "05-sea-cliffs-overcast")
        defer { bottom.app.terminate() }
        let refresh = element("background-sets.refresh", in: bottom.app)
        XCTAssertTrue(waitFor({ refresh.isEnabled }, timeout: 10), "a catalog check never finished")
        assertBottomStill(bottom, "refresh", accuracy: 0) {
            refresh.click()
            XCTAssertTrue(waitFor({ refresh.isEnabled }, timeout: 10), "the catalog check never finished")
        }
    }

    @MainActor
    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// #0624's key-event guard, moved to the picker: a picker sheet has no
    /// key event that checks catalogs, so the due check here is the one
    /// Background Sets appearing starts. It is held in flight the way a slow
    /// network holds it while the grid scrolls to the bottom, then measured
    /// through a click and the check finishing.
    @MainActor
    func testClickWithACheckDueKeepsTheGridStill() throws {
        let bottom = try openShippedAtTheBottom(
            downloaded: Self.unevenAboveDeepSpace,
            waitForAvailable: "05-sea-cliffs-overcast",
            environment: ["BATTY_UI_TEST_BACKGROUND_CATALOG_CHECK_INTERVAL": "0"],
            checkInFlight: true
        )
        defer { bottom.app.terminate() }
        let hold = catalogFolder.appending(path: "catalog.json.hold")
        defer { try? FileManager.default.removeItem(at: hold) }
        try holdDeepSpace(["08-distant-galaxy"])
        defer { releaseDeepSpace(["08-distant-galaxy"]) }
        let refresh = element("background-sets.refresh", in: bottom.app)
        XCTAssertFalse(refresh.isEnabled, "the catalog check is no longer in flight")
        let checks = BackgroundCatalogFixture.requests(in: catalogFolder).filter { $0 == "catalog.json" }.count
        assertBottomStill(bottom, "click, check in flight", accuracy: 0) { bottom.galaxy.click() }
        screenshot("clicked, check in flight")
        assertBottomStill(bottom, "check finished", accuracy: 0) {
            try? FileManager.default.removeItem(at: hold)
            XCTAssertTrue(waitFor({ refresh.isEnabled }, timeout: 10), "the catalog check never finished")
        }
        screenshot("check finished")
        let after = BackgroundCatalogFixture.requests(in: catalogFolder).filter { $0 == "catalog.json" }.count
        XCTAssertGreaterThanOrEqual(after, checks, "the held check was never logged")
        XCTAssertGreaterThanOrEqual(after, 2, "Background Sets appearing did not check the catalog again")
        XCTAssertTrue(element("background-images.picker.root", in: bottom.app).exists, "the picker closed")
    }
}
