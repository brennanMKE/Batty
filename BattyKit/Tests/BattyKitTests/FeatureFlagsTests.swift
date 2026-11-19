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

    @Test func agentIntegrationIsOnInBetaOnly() {
        #expect(FeatureFlags.resolved(bundleIdentifier: ServiceNames.Variant.beta.appBundleIdentifier).agentIntegration)
        #expect(!FeatureFlags.resolved(bundleIdentifier: ServiceNames.Variant.prod.appBundleIdentifier).agentIntegration)
        #expect(!FeatureFlags.resolved(bundleIdentifier: nil).agentIntegration)
    }

    @Test func currentIsOffUnderSwiftTest() {
        // Test builds don't pass -DBATTY_VARIANT_BETA, so the baked variant is Prod.
        #expect(ServiceNames.current == .prod)
        #expect(!FeatureFlags.current.agentIntegration)
        #expect(!FeatureFlags.current.serverPane)
    }

    @Test func serverPaneIsOnInBetaAndOffInProd() {
        #expect(FeatureFlags.resolved(bundleIdentifier: ServiceNames.Variant.beta.appBundleIdentifier, environment: [:]).serverPane)
        #expect(!FeatureFlags.resolved(bundleIdentifier: ServiceNames.Variant.prod.appBundleIdentifier, environment: [:]).serverPane)
    }

    @Test func serverPaneFailsClosedForUnknownBundle() {
        #expect(!FeatureFlags.resolved(bundleIdentifier: "com.example.other", environment: [:]).serverPane)
        #expect(!FeatureFlags.resolved(bundleIdentifier: nil, environment: [:]).serverPane)
    }

    @Test func uiTestOverrideForcesServerPaneOffButNeverOn() {
        let forceOff = [FeatureFlags.uiTestEnvironmentVar: "x", FeatureFlags.uiTestForceServerPaneOffVar: "1"]
        #expect(!FeatureFlags.resolved(bundleIdentifier: ServiceNames.Variant.beta.appBundleIdentifier, environment: forceOff).serverPane)
        #expect(!FeatureFlags.resolved(bundleIdentifier: ServiceNames.Variant.prod.appBundleIdentifier, environment: [FeatureFlags.uiTestEnvironmentVar: "x", FeatureFlags.uiTestForceServerPaneOffVar: "0"]).serverPane)
        #expect(FeatureFlags.resolved(bundleIdentifier: ServiceNames.Variant.beta.appBundleIdentifier, environment: [FeatureFlags.uiTestForceServerPaneOffVar: "1"]).serverPane)
    }
}
