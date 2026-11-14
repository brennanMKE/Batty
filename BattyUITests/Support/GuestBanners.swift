// GuestBanners.swift

import Foundation
import XCTest

/// Closes the guest's persistent macOS banners: "App Background Activity",
/// raised if Background Task Management notices the broker or CLI relay
/// agent the guest bootstraps before the tests run, and "Notifications may
/// include alerts", raised after the app's first launch requests
/// notification authorization. Both stay up until closed and
/// sit over the window's trailing toolbar, so a click there can land on a
/// banner. The VM's golden image is shared with other projects, so the
/// banners are cleared here rather than pre-approved in the image.
nonisolated enum GuestBanners {
    static var predicate: NSPredicate { NSPredicate(format: "label CONTAINS 'can run in the background' OR label CONTAINS 'Notifications may include' OR title CONTAINS 'App Background Activity'") }
    static var notificationsPredicate: NSPredicate { NSPredicate(format: "label CONTAINS 'Notifications may include'") }

    @MainActor private static var firstLaunchSettled = false

    @MainActor
    private static var center: XCUIApplication {
        XCUIApplication(bundleIdentifier: "com.apple.notificationcenterui")
    }

    /// Hovers each banner and clicks the `xmark` button that hovering
    /// reveals. Banners from one source stack: the top banner is a Group
    /// labelled "…, stacked" whose `xmark` is "Clear All", and the banners
    /// under it are Buttons with no `xmark` of their own, so the button is
    /// looked up in all of Notification Center rather than inside the
    /// hovered banner. A banner that won't close is recorded, not failed,
    /// so a test whose targets it doesn't cover still runs.
    ///
    /// Hovering a banner activates Notification Center, so a sweep that
    /// touched one re-activates `app` and fails the test if `app` doesn't
    /// come back to the front, or if Notification Center's panel stays open
    /// after every banner closed; otherwise keystrokes would go to
    /// Notification Center. Returns whether anything was dismissed.
    @MainActor
    @discardableResult
    static func dismissAll(returningFocusTo app: XCUIApplication) -> Bool {
        let center = center
        let banners = center.descendants(matching: .any).matching(predicate)
        guard banners.firstMatch.exists else { return false }
        var dismissed = false
        for _ in 0..<4 {
            let before = banners.count
            guard before > 0 else { break }
            let stacked = banners.matching(NSPredicate(format: "label ENDSWITH ', stacked'")).firstMatch
            let banner = stacked.exists ? stacked : banners.firstMatch
            guard let close = revealClose(of: banner, in: center, away: app) else {
                record("no xmark button appeared over banner '\(banner.label)'", center)
                break
            }
            close.click()
            guard BattyUITestHarness.waitFor({ banners.count < before }, timeout: 5) else {
                record("banner '\(banner.label)' is still up after clicking '\(close.label)'", center)
                break
            }
            dismissed = true
        }
        // Notification Center keeps its panel open while the pointer rests on a
        // banner, so park the pointer on the app's window before activating it.
        let window = app.windows.firstMatch
        if window.exists { window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).hover() }
        app.activate()
        guard app.wait(for: .runningForeground, timeout: 5) else {
            XCTFail("focus did not return to the app under test after sweeping banners")
            return dismissed
        }
        // A banner left up keeps Notification Center's Dialog alive without
        // focus, so the Dialog only has to go once every banner is closed.
        if !banners.firstMatch.exists, !BattyUITestHarness.waitFor({ !center.dialogs["Notification Center"].exists }, timeout: 5) {
            XCTFail("Notification Center's panel is still open after sweeping banners")
        }
        return dismissed
    }

    /// A banner that has just arrived is still sliding in, and a hover that
    /// lands mid-animation doesn't reveal `xmark`, so wait for the banner's
    /// frame to stop moving, then hover; if `xmark` still doesn't show,
    /// move the pointer away and hover once more.
    @MainActor
    private static func revealClose(of banner: XCUIElement, in center: XCUIApplication, away app: XCUIApplication) -> XCUIElement? {
        var last = CGRect.null
        _ = BattyUITestHarness.waitFor({
            let frame = banner.frame
            defer { last = frame }
            return frame == last
        }, timeout: 3)
        let close = center.descendants(matching: .button).matching(identifier: "xmark").firstMatch
        for attempt in 0..<2 {
            if attempt > 0 {
                let window = app.windows.firstMatch
                guard window.exists else { break }
                window.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.75)).hover()
            }
            guard banner.exists else { return nil }
            banner.hover()
            if close.waitForExistence(timeout: 2) { return close }
        }
        return nil
    }

    @MainActor
    private static func record(_ message: String, _ center: XCUIApplication) {
        XCTContext.runActivity(named: "Banner left up: \(message)") { activity in
            activity.add(XCTAttachment(string: center.debugDescription))
        }
    }

    /// The notifications banner arrives asynchronously after the first launch,
    /// so the first launch in a runner process waits for it (returning as soon
    /// as it appears); later launches only sweep what is already up.
    @MainActor
    static func settleAfterLaunch(app: XCUIApplication) {
        if !firstLaunchSettled {
            let banner = center.descendants(matching: .any).matching(notificationsPredicate).firstMatch
            _ = BattyUITestHarness.waitFor({ banner.exists }, timeout: 10)
            firstLaunchSettled = true
        }
        dismissAll(returningFocusTo: app)
    }
}
