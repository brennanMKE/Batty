// WindowCloseQuitTests.swift

import XCTest

/// Closing a window's last Tab closes the window, and the last content window
/// takes the app with it. Nothing may bring a closed window's runtime back,
/// because its Session would keep the app running with no windows (#0546).
nonisolated final class WindowCloseQuitTests: ProjectsUITestCase {
    private func listedWindowCount() -> Int? {
        guard let object = CLITopology.jsonObject(in: BattyCLI.run(["list", "--json"]).output),
              let windows = object["windows"] as? [[String: Any]]
        else { return nil }
        return windows.count
    }

    @MainActor
    func testClosingTheLastTabOfTheOnlyWindowQuitsTheApp() throws {
        let (app, _) = try launchApp()
        defer { app.terminate() }

        app.typeKey("w", modifierFlags: .command)

        XCTAssertTrue(app.wait(for: .notRunning, timeout: 20), "closing the last Tab did not quit the app")
    }

    @MainActor
    func testClosingEveryTabOfOneWindowLeavesNoPhantomAndClosingTheOtherQuitsTheApp() throws {
        let (app, _) = try launchApp()
        defer { app.terminate() }

        app.typeKey("n", modifierFlags: [.command, .shift])
        XCTAssertTrue(waitFor({ app.windows.count == 2 }, timeout: 10), "New Window did not open a second window")

        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(waitFor({ app.windows.count == 1 }, timeout: 10), "Cmd-W did not close the second window")
        XCTAssertEqual(listedWindowCount(), 1, "the closed window is still listed")

        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 20), "closing the other window did not quit the app")
    }
}
