// FeatureFlagsTests.swift

import BattyXPCCore
import Testing

struct FeatureFlagsTests {
    @Test func onInBeta() {
        #expect(FeatureFlags.resolved(bundleIdentifier: ServiceNames.Variant.beta.appBundleIdentifier).sharedProjectImages)
    }

    @Test func offInProd() {
        #expect(!FeatureFlags.resolved(bundleIdentifier: ServiceNames.Variant.prod.appBundleIdentifier).sharedProjectImages)
    }

    @Test func unknownIdentifierFailsClosed() {
        #expect(!FeatureFlags.resolved(bundleIdentifier: "com.example.other").sharedProjectImages)
    }

    @Test func nilIdentifierFailsClosed() {
        #expect(!FeatureFlags.resolved(bundleIdentifier: nil).sharedProjectImages)
    }

    @Test func currentIsOffUnderSwiftTest() {
        // Test builds don't pass -DBATTY_VARIANT_BETA, so the baked variant is Prod.
        #expect(ServiceNames.current == .prod)
        #expect(!FeatureFlags.current.servers)
    }

    @Test func serversIsOnInBetaAndOffInProd() {
        #expect(FeatureFlags.resolved(bundleIdentifier: ServiceNames.Variant.beta.appBundleIdentifier, environment: [:]).servers)
        #expect(!FeatureFlags.resolved(bundleIdentifier: ServiceNames.Variant.prod.appBundleIdentifier, environment: [:]).servers)
    }

    @Test func serversFailsClosedForUnknownBundle() {
        #expect(!FeatureFlags.resolved(bundleIdentifier: "com.example.other", environment: [:]).servers)
        #expect(!FeatureFlags.resolved(bundleIdentifier: nil, environment: [:]).servers)
    }

    @Test func uiTestOverrideForcesServersOffButNeverOn() {
        let forceOff = [FeatureFlags.uiTestEnvironmentVar: "x", FeatureFlags.uiTestForceServersOffVar: "1"]
        #expect(!FeatureFlags.resolved(bundleIdentifier: ServiceNames.Variant.beta.appBundleIdentifier, environment: forceOff).servers)
        #expect(!FeatureFlags.resolved(bundleIdentifier: ServiceNames.Variant.prod.appBundleIdentifier, environment: [FeatureFlags.uiTestEnvironmentVar: "x", FeatureFlags.uiTestForceServersOffVar: "0"]).servers)
        #expect(FeatureFlags.resolved(bundleIdentifier: ServiceNames.Variant.beta.appBundleIdentifier, environment: [FeatureFlags.uiTestForceServersOffVar: "1"]).servers)
    }

    @Test func compactSidebarIsOnInBetaAndOffInProd() {
        #expect(FeatureFlags.resolved(bundleIdentifier: ServiceNames.Variant.beta.appBundleIdentifier, environment: [:]).compactSidebar)
        #expect(!FeatureFlags.resolved(bundleIdentifier: ServiceNames.Variant.prod.appBundleIdentifier, environment: [:]).compactSidebar)
    }

    @Test func compactSidebarFailsClosedForUnknownBundle() {
        #expect(!FeatureFlags.resolved(bundleIdentifier: "com.example.other", environment: [:]).compactSidebar)
        #expect(!FeatureFlags.resolved(bundleIdentifier: nil, environment: [:]).compactSidebar)
    }

    @Test func uiTestOverrideForcesCompactSidebarOffButNeverOn() {
        let beta = ServiceNames.Variant.beta.appBundleIdentifier
        let forceOff = [FeatureFlags.uiTestEnvironmentVar: "x", FeatureFlags.uiTestForceCompactSidebarOffVar: "1"]
        let flags = FeatureFlags.resolved(bundleIdentifier: beta, environment: forceOff)
        #expect(!flags.compactSidebar)
        #expect(flags.servers, "each override forces only its own flag off")
        #expect(!FeatureFlags.resolved(bundleIdentifier: ServiceNames.Variant.prod.appBundleIdentifier, environment: forceOff).compactSidebar)
        #expect(FeatureFlags.resolved(bundleIdentifier: beta, environment: [FeatureFlags.uiTestForceCompactSidebarOffVar: "1"]).compactSidebar)
    }
}
