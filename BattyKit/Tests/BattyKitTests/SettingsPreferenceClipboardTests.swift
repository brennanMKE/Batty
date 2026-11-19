// SettingsPreferenceClipboardTests.swift

import Foundation
import Testing
@testable import BattyKit

@MainActor
final class SettingsPreferenceClipboardTests {
    private let testDefaults = TestDefaults()

    @MainActor deinit { testDefaults.tearDown() }

    @Test func clipboardReadDefaultsToNever() {
        #expect(SettingsPreference.resolvedClipboardReadPolicy(defaults: testDefaults.defaults) == .never)
    }

    @Test func clipboardReadUnknownValueFallsBackToNever() {
        testDefaults.defaults.set("sometimes", forKey: SettingsPreference.clipboardReadKey)
        #expect(SettingsPreference.resolvedClipboardReadPolicy(defaults: testDefaults.defaults) == .never)
    }

    @Test(arguments: [ClipboardReadPolicy.ask, .allow])
    func clipboardReadRoundTripsEachPolicy(_ policy: ClipboardReadPolicy) {
        testDefaults.defaults.set(policy.rawValue, forKey: SettingsPreference.clipboardReadKey)
        #expect(SettingsPreference.resolvedClipboardReadPolicy(defaults: testDefaults.defaults) == policy)
    }
}
