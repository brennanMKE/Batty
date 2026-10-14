// ProjectsSyncEntitlementTests.swift

import Security
import XCTest

/// The UI-test build carries no iCloud entitlement or provisioning profile
/// (#0503): a restricted entitlement without an authorizing profile gets the
/// app killed at launch, and the VM has no iCloud account anyway. Without the
/// entitlement the app builds no sync backend, so sharing never reports a
/// quota error.
nonisolated final class ProjectsSyncEntitlementTests: ProjectsUITestCase {
    private static let kvstoreKey = "com.apple.developer.ubiquity-kvstore-identifier"

    func testTheUITestBuildHasNoICloudEntitlementAndNoEmbeddedProfile() throws {
        let appURL = try BattyCLI.appBundleURL(from: Self.self)

        var staticCode: SecStaticCode?
        XCTAssertEqual(SecStaticCodeCreateWithPath(appURL as CFURL, [], &staticCode), errSecSuccess)
        var information: CFDictionary?
        XCTAssertEqual(
            SecCodeCopySigningInformation(try XCTUnwrap(staticCode), SecCSFlags(rawValue: kSecCSSigningInformation), &information),
            errSecSuccess)
        let signing = try XCTUnwrap(information as? [String: Any])
        XCTAssertNotNil(signing[kSecCodeInfoIdentifier as String], "the app is not signed at all, so the entitlement check below proves nothing")
        let entitlements = signing[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:]
        XCTAssertNil(entitlements[Self.kvstoreKey], "the BATTY_ENTITLEMENTS override did not reach the app target: \(entitlements.keys.sorted())")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: appURL.appending(path: "Contents/embedded.provisionprofile").path),
            "the UI-test build embeds a provisioning profile")
    }

    @MainActor
    func testSharingAProjectShowsNoSyncErrorCaption() throws {
        let root = try makeDirectory("Alpha")
        let (app, _) = try launchApp(projects: [
            ProjectFixture.project(
                name: "Alpha", root: root, layout: ProjectFixture.terminal(), preset: "singlePane",
                lastOpenedAt: "2026-04-01T12:00:00Z")
        ])
        defer { app.terminate() }

        presentPicker(in: app)
        let box = element("project-picker.shared.Alpha", in: app)
        XCTAssertTrue(box.waitForExistence(timeout: 5))
        box.click()
        XCTAssertTrue(waitFor({ self.isChecked(box) }, timeout: 5), "the click did not check Alpha")
        XCTAssertFalse(element("project-picker.sync-error", in: app).exists, "a share that nothing refused shows a sync error")
    }
}
