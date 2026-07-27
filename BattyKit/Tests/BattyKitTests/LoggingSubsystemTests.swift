// LoggingSubsystemTests.swift

import BattyXPCCore
import Foundation
import Testing
@testable import BattyKit

/// #0279: the broker and CLI are bare Mach-Os with no `Bundle.main`, so
/// `BattyXPCCore.Logging.subsystem` used to fall back to a hardcoded Prod
/// literal regardless of which variant shipped them, contaminating the
/// `log stream` predicate #0272 depends on. `resolvedSubsystem` pulls the
/// fallback out as an injectable pure function so both branches (a real
/// bundle identifier vs. `nil`) are directly testable.
struct LoggingSubsystemTests {

    // Qualified as `BattyXPCCore.Logging` throughout: `BattyKit` (imported
    // `@testable` for the rest of the suite) declares its own unrelated
    // `Logging` type (`Util/Logging.swift`, the app-side "fine" copy leak 2
    // doesn't touch), and the bare name is ambiguous with both imported.

    @Test func resolvedSubsystemUsesTheGivenBundleIdentifierWhenPresent() {
        #expect(BattyXPCCore.Logging.resolvedSubsystem(bundleIdentifier: "co.sstools.Batty") == "co.sstools.Batty")
        #expect(BattyXPCCore.Logging.resolvedSubsystem(bundleIdentifier: "co.sstools.Batty.beta") == "co.sstools.Batty.beta")
    }

    // review round 1: `ServiceNames.current` is baked at compile time
    // (`-DBATTY_VARIANT_BETA`, absent for this test target), so this test
    // binary is always `.prod` — comparing `resolvedSubsystem(nil)` against
    // `ServiceNames.appBundleIdentifier` alone would be tautological (both
    // sides evaluate the same expression) and would not catch an inverted
    // `#if` (the gap #0277's Gotchas already flagged: "No test pins
    // ServiceNames.current == .prod for a default no-flag build"). Pinning
    // `.current == .prod` here first makes the fallback assertion below
    // provably check Prod's literal, not just itself.
    @Test func serviceNamesCurrentIsProdForThisDefaultNoFlagTestBuild() {
        #expect(ServiceNames.current == .prod)
    }

    @Test func resolvedSubsystemFallsBackToTheCompileTimeBakedVariantWhenThereIsNoBundle() {
        // Bare Mach-Os (broker, CLI) have no adjacent Info.plist, so
        // Bundle.main.bundleIdentifier is nil at runtime — this is the
        // path both processes actually take. Asserted against the Prod
        // literal directly (not just against ServiceNames.appBundleIdentifier
        // again) now that the test above pins which variant this binary is.
        #expect(BattyXPCCore.Logging.resolvedSubsystem(bundleIdentifier: nil) == "co.sstools.Batty")
        #expect(BattyXPCCore.Logging.resolvedSubsystem(bundleIdentifier: nil) == ServiceNames.appBundleIdentifier)
    }

    @Test func subsystemStaticLetMatchesTheDefaultParameterResolution() {
        #expect(BattyXPCCore.Logging.subsystem == BattyXPCCore.Logging.resolvedSubsystem())
    }
}
