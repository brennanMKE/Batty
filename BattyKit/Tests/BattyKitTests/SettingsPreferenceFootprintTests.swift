// SettingsPreferenceFootprintTests.swift

import Foundation
import Testing
@testable import BattyKit

// UserDefaults.standard is global process state and Swift Testing runs test
// functions concurrently by default; these tests share one preference key
// with distinguishable-by-magnitude values, so .serialized keeps them from
// racing each other.
@Suite(.serialized)
struct SettingsPreferenceFootprintTests {

    @Test func resolvedFootprintSoftLimitGBFallsBackToTheDefault() {
        UserDefaults.standard.removeObject(forKey: SettingsPreference.footprintSoftLimitGBKey)
        defer { UserDefaults.standard.removeObject(forKey: SettingsPreference.footprintSoftLimitGBKey) }

        #expect(SettingsPreference.resolvedFootprintSoftLimitGB() == SettingsPreference.defaultFootprintSoftLimitGB)
    }

    @Test func resolvedFootprintSoftLimitGBHonorsAStoredValue() {
        UserDefaults.standard.set(8.0, forKey: SettingsPreference.footprintSoftLimitGBKey)
        defer { UserDefaults.standard.removeObject(forKey: SettingsPreference.footprintSoftLimitGBKey) }

        #expect(SettingsPreference.resolvedFootprintSoftLimitGB() == 8.0)
    }

    @Test func resolvedFootprintSoftLimitBytesConvertsGBToBytes() {
        UserDefaults.standard.set(2.0, forKey: SettingsPreference.footprintSoftLimitGBKey)
        defer { UserDefaults.standard.removeObject(forKey: SettingsPreference.footprintSoftLimitGBKey) }

        #expect(SettingsPreference.resolvedFootprintSoftLimitBytes() == 2 * 1_073_741_824)
    }
}
