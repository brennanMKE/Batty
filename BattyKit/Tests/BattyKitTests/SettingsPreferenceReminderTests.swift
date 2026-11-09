// SettingsPreferenceReminderTests.swift

import Foundation
import Testing
@testable import BattyKit

@MainActor
struct SettingsPreferenceReminderTests {
    private let testDefaults = TestDefaults()

    @Test func tomorrowTimeDefaultsToNineWhenUnset() {
        #expect(SettingsPreference.resolvedReminderTomorrowTime(defaults: testDefaults.defaults)
                == ReminderTime(hour: 9, minute: 0))
    }

    @Test(arguments: [-1, 1440])
    func tomorrowTimeFallsBackToNineForInvalidStoredValue(_ raw: Int) {
        testDefaults.defaults.set(raw, forKey: SettingsPreference.reminderTomorrowTimeKey)
        #expect(SettingsPreference.resolvedReminderTomorrowTime(defaults: testDefaults.defaults) == .defaultTomorrow)
    }

    @Test func tomorrowTimeFallsBackToNineForAStoredString() {
        testDefaults.defaults.set("08:30", forKey: SettingsPreference.reminderTomorrowTimeKey)
        #expect(SettingsPreference.resolvedReminderTomorrowTime(defaults: testDefaults.defaults) == .defaultTomorrow)
    }

    @Test func tomorrowTimeRoundTripsThroughThePreference() {
        SettingsPreference.storeReminderTomorrowTime(ReminderTime(hour: 8, minute: 30), defaults: testDefaults.defaults)
        #expect(SettingsPreference.resolvedReminderTomorrowTime(defaults: testDefaults.defaults)
                == ReminderTime(hour: 8, minute: 30))
        #expect(testDefaults.defaults.object(forKey: SettingsPreference.reminderTomorrowTimeKey) as? Int == 510)
    }
}
