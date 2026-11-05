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
}
