// PaneMenuViewTests.swift

import XCTest

/// Opens each non-terminal view Pane through the Pane menu's top-level
/// "Open View" section (#0453), the GUI counterpart to `CLIViewPaneTests`.
nonisolated final class PaneMenuViewTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        BattyUITestHarness.sweepSentinels()
    }

    override func tearDownWithError() throws {
        BattyUITestHarness.sweepSentinels()
    }

    @MainActor
    private func openFromPaneMenu(_ title: String, in app: XCUIApplication) {
        let paneMenu = app.menuBars.firstMatch.menuBarItems["Pane"]
        paneMenu.click()
        // The Split submenus repeat these titles one level down; only the
        // direct children of the Pane menu are the top-level entries.
        let item = paneMenu.menus.firstMatch.children(matching: .menuItem)[title]
        XCTAssertTrue(item.waitForExistence(timeout: 3), "Pane menu has no top-level \(title) item")
        item.click()
    }

    @MainActor
    func testPaneMenuOpensEachViewKind() throws {
        let app = BattyUITestHarness.launchBatty()
        defer { app.terminate() }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10), "Batty did not open a window")

        // The menu opens beside the focused Pane with no path, so Git Status
        // shows a snapshot or the not-a-repository state depending on the
        // guest's working directory; either proves the view rendered.
        let cases: [(title: String, identifiers: [String])] = [
            ("Git Status", ["git-status.snapshot", "git-status.not-a-repo"]),
            ("Process Status", ["process-status-view"]),
            ("System Metrics", ["system-metrics-pane"]),
            ("LM Studio Dashboard", ["lmstudio-dashboard"]),
        ]
        for (index, entry) in cases.enumerated() {
            openFromPaneMenu(entry.title, in: app)
            let rendered = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier IN %@", entry.identifiers))
                .firstMatch
            XCTAssertTrue(
                rendered.waitForExistence(timeout: 20),
                "none of \(entry.identifiers) appeared after Pane > \(entry.title)"
            )
            XCTAssertEqual(
                BattyScreen.identifiers(withPrefix: "pane-close-button.", in: app).count,
                index + 1,
                "Pane > \(entry.title) should add exactly one view Pane (terminal Panes have no id-keyed close button)"
            )
        }
    }
}
