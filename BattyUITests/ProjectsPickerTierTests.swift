// ProjectsPickerTierTests.swift

import XCTest

/// The two-tier Open Project picker (#0493): three large cards under Recent,
/// compact cards under All Projects, one collapsed grid while filtering, and a
/// New Project card below three Projects.
nonisolated final class ProjectsPickerTierTests: ProjectsUITestCase {
    private static let ranked = ["Bravo", "Delta Web", "Foxtrot", "Charlie Web", "Echo", "Alpha"]

    private func seed(_ names: [String]) throws -> [[String: Any]] {
        let months = ["Alpha": "01", "Bravo": "06", "Charlie Web": "03", "Delta Web": "05", "Echo": "02", "Foxtrot": "04"]
        return try names.map { name in
            ProjectFixture.project(
                name: name,
                root: try makeDirectory(name.replacingOccurrences(of: " ", with: "-")),
                layout: ProjectFixture.terminal(),
                preset: "singlePane",
                lastOpenedAt: "2026-\(months[name] ?? "01")-01T12:00:00Z"
            )
        }
    }

    @MainActor
    private func card(_ name: String, under container: String, in app: XCUIApplication) -> XCUIElement {
        element(container, in: app).descendants(matching: .any).matching(identifier: "project-picker.card.\(name)").firstMatch
    }

    @MainActor
    private func assertHint(contains name: String, in app: XCUIApplication, _ message: String = "") {
        let hint = element("project-picker.hint", in: app)
        let text = { [hint.label, (hint.value as? String) ?? ""].joined(separator: " ") }
        XCTAssertTrue(waitFor({ text().contains(name) }, timeout: 5), "the hint reads \(text()), expected \(name). \(message)")
    }

    @MainActor
    private func pressKey(_ key: XCUIKeyboardKey, in app: XCUIApplication) {
        app.typeKey(key.rawValue, modifierFlags: [])
    }

    @MainActor
    func testTiersFollowRecencyAndAnOpenedProjectMovesToTheCompactTier() throws {
        let (app, _) = try launchApp(projects: try seed(["Alpha", "Bravo", "Charlie Web", "Delta Web", "Echo", "Foxtrot"]))
        defer { app.terminate() }

        presentPicker(in: app)
        let featured = Array(Self.ranked.prefix(3))
        for name in featured {
            XCTAssertTrue(card(name, under: "project-picker.featured", in: app).waitForExistence(timeout: 5), "\(name) is not featured")
        }
        for name in Self.ranked.dropFirst(3) {
            XCTAssertTrue(card(name, under: "project-picker.rest", in: app).exists, "\(name) is not under All Projects")
            XCTAssertFalse(card(name, under: "project-picker.featured", in: app).exists, "\(name) is also featured")
        }
        let xs = featured.map { card($0, under: "project-picker.featured", in: app).frame.minX }
        XCTAssertEqual(xs, xs.sorted(), "the featured cards are not in recency order: \(xs)")
        XCTAssertFalse(element("project-picker.new-project-card", in: app).exists, "the New Project card shows with six Projects")
        XCTAssertTrue(app.staticTexts["\u{2318}N New Project\u{2026}"].exists, "the footer has no New Project hint")
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        XCTAssertTrue(waitFor({ !self.element("project-picker.root", in: app).exists }, timeout: 5))

        openThroughPicker("Bravo", in: app)
        _ = waitForSessions(named: "Bravo")
        presentPicker(in: app)
        XCTAssertTrue(card("Bravo", under: "project-picker.rest", in: app).waitForExistence(timeout: 5), "the open Project did not sink to All Projects")
        XCTAssertFalse(card("Bravo", under: "project-picker.featured", in: app).exists)
        XCTAssertTrue(element("project-picker.open-badge.Bravo", in: app).exists, "the open Project's card has no OPEN badge")
    }

    @MainActor
    func testArrowKeysCrossTheTiersAndHomeAndEndJumpToTheEnds() throws {
        let (app, _) = try launchApp(projects: try seed(["Alpha", "Bravo", "Charlie Web", "Delta Web", "Echo", "Foxtrot"]))
        defer { app.terminate() }

        presentPicker(in: app)
        assertHint(contains: "Bravo", in: app, "the first featured card is not selected")
        pressKey(.downArrow, in: app)
        assertHint(contains: "Charlie Web", in: app, "Down from featured column 0 lands on compact column 0")
        pressKey(.upArrow, in: app)
        assertHint(contains: "Bravo", in: app)
        pressKey(.end, in: app)
        assertHint(contains: "Alpha", in: app)
        pressKey(.home, in: app)
        assertHint(contains: "Bravo", in: app)

        pressKey(.downArrow, in: app)
        pressKey(.rightArrow, in: app)
        assertHint(contains: "Echo", in: app)
        pressReturn(in: app)
        XCTAssertTrue(waitFor({ !self.element("project-picker.root", in: app).exists }, timeout: 10), "the picker did not close after Return")
        _ = waitForSessions(named: "Echo")
    }

    @MainActor
    func testFilteringCollapsesToOneGridAndEscapeIsTwoStep() throws {
        let (app, _) = try launchApp(projects: try seed(["Alpha", "Bravo", "Charlie Web", "Delta Web", "Echo", "Foxtrot"]))
        defer { app.terminate() }

        presentPicker(in: app)
        let field = pickerFilterField(in: app)
        field.click()
        app.typeText("Web")
        XCTAssertTrue(card("Charlie Web", under: "project-picker.rest", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(card("Delta Web", under: "project-picker.rest", in: app).exists)
        XCTAssertFalse(element("project-picker.featured", in: app).exists, "the Recent tier shows while filtering")
        XCTAssertFalse(element("project-picker.new-project-card", in: app).exists)

        pressKey(.escape, in: app)
        XCTAssertTrue(element("project-picker.featured", in: app).waitForExistence(timeout: 5), "Escape did not bring the tiers back")
        XCTAssertTrue(element("project-picker.root", in: app).exists, "the first Escape dismissed the picker")
        XCTAssertTrue(card("Bravo", under: "project-picker.featured", in: app).exists)

        pressKey(.escape, in: app)
        XCTAssertTrue(waitFor({ !self.element("project-picker.root", in: app).exists }, timeout: 5), "the second Escape did not dismiss the picker")
    }

    @MainActor
    func testFewerThanThreeProjectsShowANewProjectCardThatOpensTheEditor() throws {
        let (app, _) = try launchApp(projects: try seed(["Alpha", "Bravo"]))
        defer { app.terminate() }

        presentPickerFromSidebar(in: app)
        XCTAssertTrue(card("Bravo", under: "project-picker.featured", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(card("Alpha", under: "project-picker.featured", in: app).exists)
        XCTAssertFalse(element("project-picker.rest", in: app).exists, "All Projects shows with two Projects")
        XCTAssertTrue(app.staticTexts["\u{2318}N New Project\u{2026}"].exists, "the footer has no New Project hint")
        click("project-picker.new-project-card", in: app)
        XCTAssertTrue(waitFor({ !self.element("project-picker.root", in: app).exists }, timeout: 10), "the picker did not close")
        XCTAssertTrue(editorWindow(in: app).waitForExistence(timeout: 10), "the New Project card did not open the Project Editor")
    }
}
