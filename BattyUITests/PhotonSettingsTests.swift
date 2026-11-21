// PhotonSettingsTests.swift

import XCTest

/// Settings ▸ General ▸ Servers' PhotonHTTP row (#0693). Never clicks
/// Install: that would run the real installer.
nonisolated final class PhotonSettingsTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        BattyUITestHarness.sweepSentinels()
    }

    override func tearDownWithError() throws {
        BattyUITestHarness.sweepSentinels()
    }

    @MainActor
    func testServersSettingsShowsPhotonNotInstalledAndInstallButton() throws {
        let app = BattyUITestHarness.launchBatty()
        defer { app.terminate() }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        app.typeKey(",", modifierFlags: [.command])
        let status = BattyScreen.element("settings.photon.status", in: app)
        XCTAssertTrue(status.waitForExistence(timeout: 10), "no PhotonHTTP row in Settings ▸ General")
        XCTAssertTrue(BattyUITestHarness.waitFor({
            let text = status.label.isEmpty ? (status.value as? String ?? "") : status.label
            return text == "Not installed"
        }, timeout: 10), "status reads \(status.label)")
        XCTAssertTrue(BattyScreen.element("settings.photon.install", in: app).exists, "no Install PhotonHTTP… button")
    }
}
