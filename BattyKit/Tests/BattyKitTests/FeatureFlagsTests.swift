// FeatureFlagsTests.swift

import Testing
@testable import BattyKit

struct FeatureFlagsTests {
    private let beta = ServiceNames.Variant.beta.appBundleIdentifier
    private let prod = ServiceNames.Variant.prod.appBundleIdentifier
    private let uiEnv = [
        FeatureFlags.uiTestEnvironmentVar: "[]",
        FeatureFlags.uiTestForceProjectsOffVar: "1",
    ]

    @Test func betaIdentifierTurnsProjectsOn() {
        #expect(FeatureFlags.resolved(bundleIdentifier: beta, environment: [:]).projects)
    }

    @Test func prodIdentifierKeepsProjectsOff() {
        #expect(!FeatureFlags.resolved(bundleIdentifier: prod, environment: [:]).projects)
    }

    @Test func nilIdentifierFailsClosed() {
        #expect(!FeatureFlags.resolved(bundleIdentifier: nil, environment: [:]).projects)
    }

    @Test func unknownIdentifierFailsClosed() {
        #expect(!FeatureFlags.resolved(bundleIdentifier: "com.example.other", environment: [:]).projects)
    }

    @Test func overrideForcesProjectsOffUnderBetaWhenUITestEnvironmentPresent() {
        #expect(!FeatureFlags.resolved(bundleIdentifier: beta, environment: uiEnv).projects)
    }

    @Test func overrideIsIgnoredWithoutUITestEnvironment() {
        let env = [FeatureFlags.uiTestForceProjectsOffVar: "1"]
        #expect(FeatureFlags.resolved(bundleIdentifier: beta, environment: env).projects)
    }

    @Test func overrideOnlyActsOnTheExactValue() {
        var env = uiEnv
        env[FeatureFlags.uiTestForceProjectsOffVar] = "0"
        #expect(FeatureFlags.resolved(bundleIdentifier: beta, environment: env).projects)
    }

    @Test func overrideCannotTurnProjectsOnUnderProd() {
        #expect(!FeatureFlags.resolved(bundleIdentifier: prod, environment: uiEnv).projects)
        #expect(!FeatureFlags.resolved(bundleIdentifier: prod, environment: [FeatureFlags.uiTestEnvironmentVar: "[]"]).projects)
    }

    @Test func currentIsOffUnderUnitTests() {
        #expect(!FeatureFlags.current.projects)
    }

    @MainActor
    @Test func appStateStoreStoresInjectedFlags() {
        for value in [true, false] {
            let store = AppStateStore(featureFlags: FeatureFlags(projects: value))
            #expect(store.featureFlags == FeatureFlags(projects: value))
        }
    }
}
