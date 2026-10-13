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
        XCTAssertTrue(card("Bravo", under: "project-picker.open-now", in: app).waitForExistence(timeout: 5), "the open Project did not move to the Open now strip")
        XCTAssertFalse(card("Bravo", under: "project-picker.rest", in: app).exists)
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

    // MARK: - Open now strip (#0500)

    @MainActor
    func testOpenProjectsLiveInTheOpenNowStripAndSwitchOrOpenAnotherCopy() throws {
        let (app, initial) = try launchApp(projects: try seed(["Alpha", "Bravo", "Charlie Web", "Delta Web"]))
        defer { app.terminate() }
        let original = try XCTUnwrap(initial?.selectedSession)

        openThroughPicker("Bravo", in: app)
        let first = try XCTUnwrap(waitForSessions(named: "Bravo").first)
        let afterOpen = try XCTUnwrap(BattyCLI.topology()).sessions.count

        let originalRow = BattyUITestHarness.sessionRow(named: original.name, in: app)
        XCTAssertTrue(originalRow.waitForExistence(timeout: 5))
        originalRow.click()
        XCTAssertNotNil(BattyCLI.waitForTopology { $0.selectedSessionID == original.id }, "selecting the original Session did not take")

        presentPicker(in: app)
        XCTAssertTrue(card("Bravo", under: "project-picker.open-now", in: app).waitForExistence(timeout: 5), "the open Project is not in the Open now strip")
        XCTAssertTrue(element("project-picker.open-badge.Bravo", in: app).exists)
        for name in ["Delta Web", "Charlie Web", "Alpha"] {
            XCTAssertTrue(card(name, under: "project-picker.featured", in: app).exists, "\(name) is not featured")
        }
        XCTAssertFalse(element("project-picker.rest", in: app).exists, "All Projects shows with three closed Projects")
        XCTAssertFalse(card("Bravo", under: "project-picker.featured", in: app).exists)

        pressKey(.end, in: app)
        assertHint(contains: "Switch to the open Bravo Session", in: app, "End did not select the strip's chip")
        pressReturn(in: app)
        XCTAssertTrue(waitFor({ !self.element("project-picker.root", in: app).exists }, timeout: 10), "the picker did not close after Return")
        let found = try XCTUnwrap(BattyCLI.waitForTopology { $0.selectedSessionID == first.id }, "Return did not select the open Session")
        XCTAssertEqual(found.sessions.count, afterOpen, "Return opened another Session instead of switching")

        presentPicker(in: app)
        click("project-picker.open-now.another.Bravo", in: app)
        XCTAssertTrue(waitFor({ !self.element("project-picker.root", in: app).exists }, timeout: 10), "the picker did not close after the + button")
        let copied = try XCTUnwrap(BattyCLI.waitForTopology { $0.sessions.count == afterOpen + 1 }, "the + button did not open another Session")
        XCTAssertNotEqual(copied.selectedSessionID, first.id, "the + button selected the existing Session")
        let copy = try XCTUnwrap(copied.selectedSessionID.flatMap { copied.session($0) }, "the new Session is not selected")
        XCTAssertEqual(copy.name, "Bravo", "the new Session is not a Bravo Session")
        _ = waitForSessions(named: "Bravo", count: 2)
    }

    @MainActor
    func testFilteringHidesTheOpenNowStripAndEscapeRestoresIt() throws {
        let (app, _) = try launchApp(projects: try seed(["Alpha", "Bravo", "Charlie Web", "Delta Web"]))
        defer { app.terminate() }

        openThroughPicker("Bravo", in: app)
        _ = waitForSessions(named: "Bravo")
        presentPicker(in: app)
        XCTAssertTrue(element("project-picker.open-now", in: app).waitForExistence(timeout: 5))

        pickerFilterField(in: app).click()
        app.typeText("Brav")
        XCTAssertTrue(card("Bravo", under: "project-picker.rest", in: app).waitForExistence(timeout: 5), "the open match is not in the filtered grid")
        XCTAssertTrue(element("project-picker.open-badge.Bravo", in: app).exists)
        XCTAssertTrue(waitFor({ !self.element("project-picker.open-now", in: app).exists }, timeout: 5), "the strip shows while filtering")

        pressKey(.escape, in: app)
        XCTAssertTrue(element("project-picker.open-now", in: app).waitForExistence(timeout: 5), "Escape did not restore the strip")
        XCTAssertTrue(element("project-picker.root", in: app).exists)
    }
}
