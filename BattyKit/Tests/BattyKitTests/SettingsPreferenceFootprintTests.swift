// SettingsPreferenceFootprintTests.swift

import Foundation
import Testing
@testable import BattyKit

struct SettingsPreferenceFootprintTests {

    @Test func resolvedFootprintSoftLimitGBFallsBackToTheDefault() {
        let testDefaults = TestDefaults()
        defer { testDefaults.tearDown() }
        #expect(SettingsPreference.resolvedFootprintSoftLimitGB(defaults: testDefaults.defaults) == SettingsPreference.defaultFootprintSoftLimitGB)
    }

    @Test func resolvedFootprintSoftLimitGBHonorsAStoredValue() {
        let testDefaults = TestDefaults()
        defer { testDefaults.tearDown() }
        testDefaults.defaults.set(8.0, forKey: SettingsPreference.footprintSoftLimitGBKey)

        #expect(SettingsPreference.resolvedFootprintSoftLimitGB(defaults: testDefaults.defaults) == 8.0)
    }

    @Test func resolvedFootprintSoftLimitBytesConvertsGBToBytes() {
        let testDefaults = TestDefaults()
        defer { testDefaults.tearDown() }
        testDefaults.defaults.set(2.0, forKey: SettingsPreference.footprintSoftLimitGBKey)

        #expect(SettingsPreference.resolvedFootprintSoftLimitBytes(defaults: testDefaults.defaults) == 2 * 1_073_741_824)
    }
}
