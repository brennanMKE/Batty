// ProjectsSharingTests.swift

import XCTest

/// The Shared checkbox on picker cards, Open now chips and in the Project
/// Editor (#0501). The checkbox is its own click target: it writes at once
/// and neither selects, opens nor dismisses.
nonisolated final class ProjectsSharingTests: ProjectsUITestCase {
    private func seed() throws -> [[String: Any]] {
        let names = [("Alpha", "04", false), ("Bravo", "03", true), ("Charlie", "02", false), ("Delta", "01", false)]
        return try names.map { name, month, shared in
            ProjectFixture.project(
                name: name,
                root: name == "Charlie" ? scratch.appending(path: "does-not-exist") : try makeDirectory(name),
                layout: ProjectFixture.terminal(),
                preset: "singlePane",
                lastOpenedAt: "2026-\(month)-01T12:00:00Z",
                isShared: shared ? true : nil,
                modifiedAt: shared ? "2026-02-01T12:00:00Z" : nil)
        }
    }

    @MainActor
    private func sharedBox(_ name: String, in app: XCUIApplication) -> XCUIElement {
        element("project-picker.shared.\(name)", in: app)
    }

    @MainActor
    private func hintText(in app: XCUIApplication) -> String {
        let hint = element("project-picker.hint", in: app)
        return [hint.label, (hint.value as? String) ?? ""].joined(separator: " ")
    }

    @MainActor
    private func sessionCount() -> Int {
        BattyCLI.topology()?.sessions.count ?? -1
    }

    /// The store re-encodes every date with fractional seconds, so seeded and
    /// stored strings for one instant differ; compare them as dates.
    private func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    private func stored(_ name: String) -> [String: Any]? {
        ProjectFixture.read(storeFile)?.first { $0["name"] as? String == name }
    }

    @MainActor
    func testEveryCardCarriesTheSharedCheckboxAndOnlyAMissingFolderShowsTheCaption() throws {
        let (app, _) = try launchApp(projects: try seed())
        defer { app.terminate() }

        presentPicker(in: app)
        for name in ["Alpha", "Bravo", "Charlie", "Delta"] {
            XCTAssertTrue(sharedBox(name, in: app).waitForExistence(timeout: 5), "no Shared checkbox on \(name)")
            XCTAssertEqual(isChecked(sharedBox(name, in: app)), name == "Bravo", "\(name) shows the wrong Shared value")
            XCTAssertEqual(element("project-picker.missing-root.\(name)", in: app).exists, name == "Charlie", "\(name) has the wrong folder caption")
        }
    }

    @MainActor
    func testClickingACompactCheckboxFlipsItWithoutSelectingOpeningOrDismissing() throws {
        let seeded = try seed()
        let (app, _) = try launchApp(projects: seeded)
        defer { app.terminate() }
        let initialSessions = sessionCount()

        presentPicker(in: app)
        XCTAssertTrue(hintText(in: app).contains("Alpha"), "Alpha is not the initial selection: \(hintText(in: app))")
        let delta = sharedBox("Delta", in: app)
        XCTAssertTrue(delta.waitForExistence(timeout: 5))
        XCTAssertFalse(isChecked(delta))

        delta.click()
        XCTAssertTrue(waitFor({ self.isChecked(self.sharedBox("Delta", in: app)) }, timeout: 5), "the click did not check Delta")
        XCTAssertTrue(hintText(in: app).contains("Alpha"), "the click moved the selection: \(hintText(in: app))")
        XCTAssertTrue(element("project-picker.root", in: app).exists, "the click dismissed the sheet")
        XCTAssertEqual(sessionCount(), initialSessions, "the click opened a Session")

        sharedBox("Delta", in: app).doubleClick()
        XCTAssertTrue(element("project-picker.root", in: app).exists, "the double-click dismissed the sheet")
        XCTAssertEqual(sessionCount(), initialSessions, "the double-click opened a Session")
        XCTAssertTrue(hintText(in: app).contains("Alpha"), "the double-click moved the selection: \(hintText(in: app))")
        XCTAssertTrue(waitFor({ self.isChecked(self.sharedBox("Delta", in: app)) }, timeout: 5), "two toggles must net to no change")

        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        XCTAssertTrue(waitFor({ !self.element("project-picker.root", in: app).exists }, timeout: 5))

        let delta2 = try XCTUnwrap(stored("Delta"))
        XCTAssertEqual(delta2["isShared"] as? Bool, true)
        XCTAssertNotNil(delta2["modifiedAt"] as? String, "the write did not stamp modifiedAt")
        for name in ["Alpha", "Bravo", "Charlie"] {
            let before = try XCTUnwrap(seeded.first { $0["name"] as? String == name })
            let after = try XCTUnwrap(stored(name))
            XCTAssertEqual(after["isShared"] as? Bool, before["isShared"] as? Bool, "\(name) changed its shared flag")
            XCTAssertEqual(date(after["modifiedAt"]), date(before["modifiedAt"]), "\(name) was restamped")
        }

        presentPicker(in: app)
        XCTAssertTrue(waitFor({ self.isChecked(self.sharedBox("Delta", in: app)) }, timeout: 5), "the value did not persist across reopening the picker")
    }

    @MainActor
    func testTheOpenNowChipHasItsOwnSharedToggle() throws {
        let (app, _) = try launchApp(projects: try seed())
        defer { app.terminate() }

        openThroughPicker("Bravo", in: app)
        _ = waitForSessions(named: "Bravo")
        let afterOpen = sessionCount()
        presentPicker(in: app)
        let strip = element("project-picker.open-now", in: app)
        XCTAssertTrue(strip.waitForExistence(timeout: 5))
        let chipBox = strip.descendants(matching: .any).matching(identifier: "project-picker.shared.Bravo").firstMatch
        XCTAssertTrue(chipBox.waitForExistence(timeout: 5), "the chip has no Shared toggle")
        XCTAssertTrue(isChecked(chipBox), "Bravo was seeded shared")
        let hint = hintText(in: app)

        chipBox.click()

        XCTAssertTrue(waitFor({ !self.isChecked(chipBox) }, timeout: 5), "the click did not uncheck Bravo")
        XCTAssertTrue(element("project-picker.root", in: app).exists, "the chip toggle dismissed the sheet")
        XCTAssertEqual(sessionCount(), afterOpen, "the chip toggle switched or opened a Session")
        XCTAssertEqual(hintText(in: app), hint, "the chip toggle changed the selection")
    }

    @MainActor
    func testEditorSharedCheckboxIsPartOfTheDraft() throws {
        let (app, _) = try launchApp(projects: try seed())
        defer { app.terminate() }

        openEditorFromFileMenu(in: app)
        click("project-editor.list.row.Alpha", in: app)
        let box = element("project-editor.shared", in: app)
        XCTAssertTrue(box.waitForExistence(timeout: 5), "the editor header has no Shared checkbox")
        XCTAssertFalse(isChecked(box), "Alpha was seeded local")
        let save = element("project-editor.save", in: app)
        XCTAssertFalse(save.isEnabled, "Save is enabled before any edit")

        dismissBanners()
        box.click()
        XCTAssertTrue(waitFor({ self.isChecked(box) }, timeout: 5), "the click did not check the box")
        XCTAssertTrue(waitFor({ save.isEnabled }, timeout: 5), "checking Shared did not enable Save")
        save.click()
        XCTAssertTrue(waitFor({ self.stored("Alpha")?["isShared"] as? Bool == true }, timeout: 10), "Save did not write isShared")

        click("project-editor.cancel", in: app)
        XCTAssertTrue(waitFor({ !self.editorWindow(in: app).exists }, timeout: 10))
        openEditorFromFileMenu(in: app)
        click("project-editor.list.row.Alpha", in: app)
        XCTAssertTrue(waitFor({ self.isChecked(self.element("project-editor.shared", in: app)) }, timeout: 5), "the saved value was not shown on reopening")

        element("project-editor.shared", in: app).click()
        XCTAssertTrue(waitFor({ !self.isChecked(self.element("project-editor.shared", in: app)) }, timeout: 5))
        click("project-editor.cancel", in: app)
        XCTAssertEqual(stored("Alpha")?["isShared"] as? Bool, true, "Cancel wrote the unchecked value")
        XCTAssertTrue(waitFor({ !self.editorWindow(in: app).exists }, timeout: 10))
        openEditorFromFileMenu(in: app)
        click("project-editor.list.row.Alpha", in: app)
        XCTAssertTrue(waitFor({ self.isChecked(self.element("project-editor.shared", in: app)) }, timeout: 5), "Cancel did not leave the box checked")

        click("project-editor.new-project", in: app)
        XCTAssertTrue(waitFor({ !self.isChecked(self.element("project-editor.shared", in: app)) }, timeout: 5), "a new Project starts shared")
    }
}
