// FeatureFlagsTests.swift

import Testing
@testable import BattyKit

struct FeatureFlagsTests {
    private let beta = ServiceNames.Variant.beta.appBundleIdentifier
    private let prod = ServiceNames.Variant.prod.appBundleIdentifier
    private let uiEnv = [
        FeatureFlags.uiTestEnvironmentVar: "[]",
        FeatureFlags.uiTestForceBackgroundsOffVar: "1",
    ]

    @Test func betaIsOn() {
        #expect(FeatureFlags.resolved(bundleIdentifier: beta, environment: [:]).terminalBackgrounds)
    }

    @Test func prodIsOff() {
        #expect(!FeatureFlags.resolved(bundleIdentifier: prod, environment: [:]).terminalBackgrounds)
    }

    @Test func nilAndUnknownBundleFailClosed() {
        #expect(!FeatureFlags.resolved(bundleIdentifier: nil, environment: [:]).terminalBackgrounds)
        #expect(!FeatureFlags.resolved(bundleIdentifier: "com.example.other", environment: [:]).terminalBackgrounds)
    }

    @Test func uiTestOverrideForcesOff() {
        #expect(!FeatureFlags.resolved(bundleIdentifier: beta, environment: uiEnv).terminalBackgrounds)
    }

    @Test func overrideIsIgnoredWithoutTheUITestDriver() {
        let env = [FeatureFlags.uiTestForceBackgroundsOffVar: "1"]
        #expect(FeatureFlags.resolved(bundleIdentifier: beta, environment: env).terminalBackgrounds)
    }

    @Test func overrideCannotForceOn() {
        #expect(!FeatureFlags.resolved(bundleIdentifier: prod, environment: uiEnv).terminalBackgrounds)
    }
}
