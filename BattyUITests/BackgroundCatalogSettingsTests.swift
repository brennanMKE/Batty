// BackgroundCatalogSettingsTests.swift

import XCTest

/// Settings → Appearance → Background Catalogs (#0577), against catalogs
/// served from a local fixture folder. Never the network.
nonisolated final class BackgroundCatalogSettingsTests: ProjectsUITestCase {
    private let host = "catalogs.example.com"
    private let setName = "Hosted Harbors"
    private var catalogFolder: URL { scratch.appending(path: "catalog-fixture") }
    private var userURL: String { "https://\(host)/catalog.json" }

    @MainActor
    private func launch() throws -> XCUIApplication {
        try BackgroundCatalogFixture.write(in: catalogFolder)
        let (app, _) = try launchApp(
            projects: [],
            connectCLI: false,
            extraEnvironment: [BackgroundCatalogFixture.envVar: catalogFolder.path]
        )
        return app
    }

    @MainActor
    private func openAppearanceSettings(in app: XCUIApplication) {
        app.typeKey(",", modifierFlags: [.command])
        let appearance = app.toolbars.buttons["Appearance"]
        XCTAssertTrue(appearance.waitForExistence(timeout: 10))
        appearance.click()
        XCTAssertTrue(element("background-catalogs.auto-check", in: app).waitForExistence(timeout: 5), "no Background Catalogs section")
    }

    @MainActor
    private func row(_ url: String, in app: XCUIApplication) -> XCUIElement {
        element("background-catalogs.row.\(url)", in: app)
    }

    @MainActor
    private func add(_ url: String, in app: XCUIApplication) {
        let field = app.textFields["background-catalogs.url-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.click()
        field.typeText(url)
        app.buttons["background-catalogs.add"].click()
    }

    @MainActor
    private func addError(in app: XCUIApplication) -> XCUIElement {
        element("background-catalogs.add-error", in: app)
    }

    @MainActor
    func testBuiltInCatalogIsListedWithoutRemove() throws {
        let app = try launch()
        defer { app.terminate() }
        openAppearanceSettings(in: app)
        let builtIn = row("https://batty.sstools.co/backgrounds/catalog.json", in: app)
        XCTAssertTrue(builtIn.waitForExistence(timeout: 5), "no built-in row")
        XCTAssertTrue(builtIn.staticTexts["Batty (built in)"].exists)
        XCTAssertTrue(builtIn.buttons["background-catalogs.check-now"].exists)
        XCTAssertFalse(builtIn.buttons["background-catalogs.remove"].exists)
    }

    @MainActor
    func testAddingAnHTTPURLIsRefused() throws {
        let app = try launch()
        defer { app.terminate() }
        openAppearanceSettings(in: app)
        add("http://example.com/catalog.json", in: app)
        let error = addError(in: app)
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        XCTAssertEqual(error.value as? String ?? error.label, "Only https:// URLs can be added")
        XCTAssertFalse(row("http://example.com/catalog.json", in: app).exists)
    }

    @MainActor
    func testAddingAPageThatIsNotACatalogIsRefused() throws {
        try BackgroundCatalogFixture.writeHTML(in: catalogFolder, host: host)
        let app = try launch()
        defer { app.terminate() }
        openAppearanceSettings(in: app)
        add(userURL, in: app)
        let error = addError(in: app)
        XCTAssertTrue(error.waitForExistence(timeout: 10))
        XCTAssertEqual(error.value as? String ?? error.label, "Not a background catalog: (root)")
        XCTAssertFalse(row(userURL, in: app).exists)
    }

    @MainActor
    func testAddedCatalogsSetsAppearInBackgroundSets() throws {
        try BackgroundCatalogFixture.writeHostedCatalog(in: catalogFolder, host: host, setName: setName)
        let app = try launch()
        defer { app.terminate() }
        openAppearanceSettings(in: app)
        add(userURL, in: app)
        XCTAssertTrue(row(userURL, in: app).waitForExistence(timeout: 10), "the catalog was not added")
        app.buttons["appearance-background.manage-images"].click()
        let tab = app.radioButtons["Background Sets"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 5))
        tab.click()
        XCTAssertTrue(element("background-sets.set.\(setName)", in: app).waitForExistence(timeout: 15), "the added catalog's set is not shown")
    }

    @MainActor
    func testRemovingACatalogKeepsTheBackgroundInUse() throws {
        try BackgroundCatalogFixture.writeHostedCatalog(in: catalogFolder, host: host, setName: setName)
        let app = try launch()
        // The pick lands in the app's real defaults and TerminalBackgrounds/
        // folder, which classes launched without the catalog fixture never
        // reset. A teardown block still runs after a failed assertion stops
        // the test, where a `defer` would not.
        addTeardownBlock { @MainActor in
            self.clearAppWideBackground(in: app)
            app.terminate()
        }
        openAppearanceSettings(in: app)
        add(userURL, in: app)
        XCTAssertTrue(row(userURL, in: app).waitForExistence(timeout: 10), "the catalog was not added")

        app.buttons["appearance-background.choose-image"].click()
        XCTAssertTrue(element("background-images.picker.root", in: app).waitForExistence(timeout: 5))
        let tab = app.radioButtons["Background Sets"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 5))
        tab.click()
        let imageID = BackgroundCatalogFixture.hostedImageIDs(setName: setName)[0]
        let root = element("background-sets.root", in: app)
        XCTAssertTrue(root.waitForExistence(timeout: 5))
        let cell = element("background-sets.cell.\(imageID)", in: app)
        root.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).hover()
        for _ in 0..<40 where !(cell.exists && cell.isHittable) {
            root.scroll(byDeltaX: 0, deltaY: -120)
        }
        XCTAssertTrue(cell.exists && cell.isHittable, "no cell for \(imageID)")
        cell.click()
        XCTAssertTrue(waitFor({ !self.element("background-images.picker.root", in: app).exists }, timeout: 15), "the picker stayed open")
        let noImage = app.buttons["appearance-background.no-image"]
        XCTAssertTrue(waitFor({ noImage.isEnabled }, timeout: 10), "the pick did not set an image")

        row(userURL, in: app).buttons["background-catalogs.remove"].click()
        XCTAssertTrue(waitFor({ !self.row(self.userURL, in: app).exists }, timeout: 10), "the catalog was not removed")
        XCTAssertTrue(noImage.isEnabled, "removing the catalog cleared the background")
    }

    @MainActor
    private func clearAppWideBackground(in app: XCUIApplication) {
        guard app.state != .notRunning else { return }
        if element("background-images.picker.root", in: app).exists {
            app.typeKey(.escape, modifierFlags: [])
        }
        let noImage = app.buttons["appearance-background.no-image"]
        guard noImage.waitForExistence(timeout: 5), noImage.isEnabled else { return }
        noImage.click()
        XCTAssertTrue(waitFor({ !noImage.isEnabled }, timeout: 10), "the app-wide background was not cleared")
    }

    @MainActor
    func testAMissingCatalogShowsItsErrorOnItsRowOnly() throws {
        try BackgroundCatalogFixture.writeHostedCatalog(in: catalogFolder, host: host, setName: setName)
        let app = try launch()
        defer { app.terminate() }
        openAppearanceSettings(in: app)
        add(userURL, in: app)
        let userRow = row(userURL, in: app)
        XCTAssertTrue(userRow.waitForExistence(timeout: 10), "the catalog was not added")
        try FileManager.default.removeItem(at: catalogFolder.appending(path: "hosts/\(host)/catalog.json"))
        userRow.buttons["background-catalogs.check-now"].click()
        let status = userRow.staticTexts["background-catalogs.status"]
        XCTAssertTrue(waitFor({ (status.value as? String ?? status.label) == "Not found (404)" }, timeout: 10), "the row did not show the error")
        let builtInStatus = row("https://batty.sstools.co/backgrounds/catalog.json", in: app).staticTexts["background-catalogs.status"]
        XCTAssertNotEqual(builtInStatus.value as? String ?? builtInStatus.label, "Not found (404)")
    }
}
