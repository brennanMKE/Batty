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
}
