// GuestBanners.swift

import Foundation
import XCTest

/// Closes the guest's persistent macOS banners: "App Background Activity",
/// raised when the guest bootstraps the broker LaunchAgent before the tests
/// run, and "Notifications may include alerts", raised after the app's first
/// launch requests notification authorization. Both stay up until closed and
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

    /// Hovers each banner to reveal Close and clicks it, with a swipe as the
    /// fallback. Returns whether anything was dismissed.
    @MainActor
    @discardableResult
    static func dismissAll() -> Bool {
        var dismissed = false
        let center = center
        for _ in 0..<4 {
            let banner = center.descendants(matching: .any).matching(predicate).firstMatch
            guard banner.exists else { break }
            dismissed = true
            banner.hover()
            let close = center.groups["AXNotificationListItems"].buttons["Close"].firstMatch
            if close.waitForExistence(timeout: 2) { close.click() } else { banner.swipeRight() }
            _ = BattyUITestHarness.waitFor({ !banner.exists }, timeout: 5)
        }
        return dismissed
    }

    /// The notifications banner arrives asynchronously after the first launch,
    /// so the first launch in a runner process waits for it (returning as soon
    /// as it appears); later launches only sweep what is already up.
    @MainActor
    static func settleAfterLaunch() {
        if !firstLaunchSettled {
            let banner = center.descendants(matching: .any).matching(notificationsPredicate).firstMatch
            _ = BattyUITestHarness.waitFor({ banner.exists }, timeout: 10)
            firstLaunchSettled = true
        }
        dismissAll()
    }
}
