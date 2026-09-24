// SessionCommandOpenURLTests.swift

import ArgumentParser
import BattyXPCCore
import Foundation
import Testing
@testable import batty

/// Covers `openURL`'s `resolveAppBundle` seam (#0361 round 3). Only the
/// failure branch is testable here: a `resolveAppBundle` success falls
/// through to a real `/usr/bin/open -a <bundlePath> <url>` `Process`
/// invocation with no injection seam of its own — spawning that from a
/// unit test would launch or activate a real app bundle. The failure
/// branch never reaches `Process` at all, so it's exercised directly.
struct SessionCommandOpenURLTests {

    @Test func bundleResolutionFailureExitsWithAppBundleUnresolvedWithoutSpawningOpen() {
        let failure = AppBundleLocator.Failure.expectedBundleMissing(expectedPath: "/Applications/Batty.app", otherClaimants: [])
        let url = URL(string: "batty://session?path=/tmp")!

        #expect(throws: ExitCode(XPCExitCode.appBundleUnresolved)) {
            try openURL(url, resolveAppBundle: { .failure(failure) })
        }
    }
}
