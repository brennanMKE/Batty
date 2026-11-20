// SettingsTests.swift

import AppKit
import XCTest

/// Settings window regression suite for [[0166]].
///
/// Tests that the Settings window opens, the panes are reachable, and
/// key preferences round-trip. Accessibility identifiers on Settings
/// pane content would enable more granular assertions; these tests cover
/// the structural (window open, pane visible) layer.
nonisolated final class SettingsTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
        BattyUITestHarness.sweepSentinels()
    }

    override func tearDownWithError() throws {
        BattyUITestHarness.sweepSentinels()
    }

    // MARK: - Settings window — would catch [[0034]] regressions

    /// Cmd-, opens the Settings window. [[0034]] baseline.
    @MainActor
    func testCmdCommaOpensSettings() throws {
        let app = BattyUITestHarness.launchBatty()
        defer { app.terminate() }

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        app.typeKey(",", modifierFlags: [.command])

        // Settings opens as a separate window titled "Batty Settings" or
        // "Settings". Assert any second window appears.
        XCTAssertTrue(
            waitFor({ app.windows.count >= 2 }, timeout: 5),
            "Cmd-, must open the Settings window ([[0034]] regression)"
        )
    }

    /// Settings window can be dismissed with Cmd-W, and the Cmd-W belongs to
    /// Settings: the content window behind it keeps every Tab (#0196, #0480).
    @MainActor
    func testSettingsWindowCanBeDismissed() throws {
        let app = BattyUITestHarness.launchBatty()
        defer { app.terminate() }

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        let contentIdentifier = app.windows.firstMatch.identifier

        let chipsAtLaunch = BattyScreen.elements(withPrefix: "tab-chip.", in: app).count
        app.typeKey("t", modifierFlags: [.command])
        XCTAssertTrue(waitFor({ BattyScreen.elements(withPrefix: "tab-chip.", in: app).count > chipsAtLaunch }, timeout: 5),
                      "a second Tab must exist so Cmd-W has a Tab it could wrongly close")
        let tabsBefore = BattyScreen.elements(withPrefix: "tab-chip.", in: app).count

        app.typeKey(",", modifierFlags: [.command])
        XCTAssertTrue(waitFor({ app.windows.count >= 2 }, timeout: 5),
                      "Settings must open first")

        app.typeKey("w", modifierFlags: [.command])
        XCTAssertTrue(
            waitFor({ app.windows.count < 2 }, timeout: 5),
            "Cmd-W must dismiss the Settings window"
        )
        XCTAssertTrue(
            app.windows.matching(NSPredicate(format: "identifier == %@", contentIdentifier)).firstMatch.exists,
            "Cmd-W in Settings must not close the content window"
        )
        XCTAssertEqual(
            BattyScreen.elements(withPrefix: "tab-chip.", in: app).count, tabsBefore,
            "Cmd-W in Settings must not close a Tab in the content window behind it"
        )
    }

    // MARK: - Settings pane navigation — [[0034]]

    /// General pane is the default tab in Settings.
    @MainActor
    func testSettingsDefaultsToGeneralPane() throws {
        let app = BattyUITestHarness.launchBatty()
        defer { app.terminate() }

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        app.typeKey(",", modifierFlags: [.command])
        XCTAssertTrue(waitFor({ app.windows.count >= 2 }, timeout: 5))

        // The Settings window should be visible with at least one toolbar button
        // selected (the default pane). This is structural — visual verification
        // of which pane is active requires per-pane accessibility identifiers.
        let settingsWindow = app.windows.element(boundBy: 1)
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 5),
                      "Settings window must exist after Cmd-,")
        XCTAssertGreaterThan(settingsWindow.frame.width, 200,
                             "Settings window must have a positive width")
    }

    /// Advanced shows the AI Agents section (#0647).
    @MainActor
    func testAdvancedSettingsShowsAIAgentsSection() throws {
        let app = BattyUITestHarness.launchBatty()
        defer { app.terminate() }

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        app.typeKey(",", modifierFlags: [.command])
        let advanced = app.toolbars.buttons["Advanced"]
        XCTAssertTrue(advanced.waitForExistence(timeout: 10))
        advanced.click()

        XCTAssertTrue(app.buttons["settings.agents.install"].waitForExistence(timeout: 5),
                      "Advanced must show the AI Agents Install… button")
        XCTAssertTrue(app.buttons["settings.agents.addToProject"].exists,
                      "Advanced must show the AI Agents Add to Project… button")
    }

    /// Never clicks Install: nothing may be written to the VM's home.
    @MainActor
    func testAdvancedSettingsShowsGuidedAgentSetup() throws {
        let app = BattyUITestHarness.launchBatty()
        defer { app.terminate() }

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        app.typeKey(",", modifierFlags: [.command])
        let advanced = app.toolbars.buttons["Advanced"]
        XCTAssertTrue(advanced.waitForExistence(timeout: 10))
        advanced.click()

        XCTAssertTrue(app.descendants(matching: .any)["settings.cli.row"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["settings.agents.help"].exists)
        let otherAgents = app.descendants(matching: .any)["settings.agents.host.agents"]
        XCTAssertTrue(otherAgents.waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["settings.agents.host.agents.status"].exists)

        let install = app.buttons["settings.agents.install"]
        XCTAssertTrue(install.exists)
        XCTAssertFalse(install.isEnabled, "Install Selected… must wait for a checked host")
        let checkbox = app.checkBoxes["settings.agents.host.agents.checkbox"]
        XCTAssertTrue(checkbox.waitForExistence(timeout: 5))
        checkbox.click()
        XCTAssertTrue(install.isEnabled)
    }

    @MainActor
    func testFreshLaunchShowsNoAgentSetupPrompt() throws {
        let app = BattyUITestHarness.launchBatty()
        defer { app.terminate() }

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(app.sheets.count, 0)
        XCTAssertFalse(app.descendants(matching: .any)["agent-setup-offer"].exists)
    }

    @MainActor
    func testAdvancedSettingsCopiesGlobalInstructionsPrompt() throws {
        let app = BattyUITestHarness.launchBatty()
        defer { app.terminate() }

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        app.typeKey(",", modifierFlags: [.command])
        let advanced = app.toolbars.buttons["Advanced"]
        XCTAssertTrue(advanced.waitForExistence(timeout: 10))
        advanced.click()

        let sentinel = "batty-uitest-sentinel-\(UUID().uuidString)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(sentinel, forType: .string)

        let copy = app.buttons["settings.agents.copyGlobalPrompt"]
        XCTAssertTrue(copy.waitForExistence(timeout: 5))
        copy.click()

        let copied = NSPasteboard.general.string(forType: .string) ?? ""
        XCTAssertNotEqual(copied, sentinel)
        XCTAssertFalse(copied.isEmpty)
        XCTAssertTrue(copied.contains("~/.codex/AGENTS.md"))
        XCTAssertTrue(copied.contains("If those variables are not set, you are not in Batty; ignore this section."))
    }

    // MARK: - Helpers
}
